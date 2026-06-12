# Window management for ElectronCall.
#
# Handles Electron window creation, content loading, and window lifecycle management.

# Window struct is defined in ElectronCall.jl
# Internal constructor function
function Window(app::Application, id::Int64; msg_channel_size::Int = 128)
    window = Window(app, id, true, Channel{Any}(msg_channel_size))
    push!(app.windows, window)
    return window
end

function Base.show(io::IO, win::Window)
    state = isopen(win) ? "open" : "closed"
    print(io, "Window(id=$(win.id), app=\"$(win.app.name)\") [$state]")
end

"""
    Window([app::Application,] args...; kwargs...) -> Window

Create a new Electron window. If no application is provided, uses the default application.

# Arguments
- `app::Application`: The application to create the window in (optional)
- `uri_or_options`: Either a URI/path to load, or a Dict of BrowserWindow options

# Keywords
- `options::Dict = Dict()`: Additional BrowserWindow options
- `width::Int = 800`: Window width
- `height::Int = 600`: Window height
- `show::Bool = true`: Whether to show window immediately
- `title::String = ""`: Window title

# Examples
```julia
# Simple window with URL
win = Window("https://example.com")

# Window with custom options
win = Window(width=1200, height=800, title="My App")

# Window with specific application
app = Application()
win = Window(app, "file:///path/to/index.html")

# Window with full BrowserWindow options
win = Window(Dict(
    "width" => 1000,
    "height" => 700,
    "webPreferences" => Dict("contextIsolation" => true)
))
```
"""
function Window(app::Application, options::Dict = OptDict(); kwargs...)
    # Merge kwargs into options
    merged_options = merge(options, Dict(string(k) => v for (k, v) in kwargs))

    # Apply security defaults from application
    apply_security_defaults!(merged_options, app.security_config)

    # Send window creation request
    message = OptDict("cmd" => "newwindow", "options" => merged_options)
    retval = req_response(app, message)

    if haskey(retval, "error")
        throw(ApplicationError("Failed to create window: $(retval["error"])"))
    end

    window_id = retval["data"]
    return Window(app, window_id)
end

# Convenience constructors
Window(app::Application, uri::URI; kwargs...) =
    Window(app, Dict("url" => string(uri)); kwargs...)

# For file paths and URLs (strings that don't look like HTML)
function Window(app::Application, path::AbstractString; kwargs...)
    # If it looks like HTML content (contains tags), treat as HTML
    if occursin(r"<\w+.*?>"s, path)
        return Window(
            app,
            URI("data:text/html;charset=utf-8," * escapeuri(path));
            kwargs...,
        )
    else
        # Otherwise treat as URL/file path
        return Window(app, URI(path); kwargs...)
    end
end

# Default application constructors
Window(args...; kwargs...) = Window(default_application(), args...; kwargs...)

"""
    load(win::Window, content)

Load content into the window. Content can be a URI, file path, or HTML string.

# Examples
```julia
load(win, URI("https://example.com"))
load(win, "/path/to/file.html")
load(win, "<h1>Hello World</h1>")
```
"""
function load(win::Window, uri::URI)
    isopen(win) || throw(WindowClosedError(win.id, "load"))

    message = OptDict("cmd" => "loadurl", "winid" => win.id, "url" => string(uri))
    retval = req_response(win.app, message)

    if haskey(retval, "error")
        throw(
            JSExecutionError(
                "Failed to load URL: $(retval["error"])",
                context = "renderer",
            ),
        )
    end

    return nothing
end

# Load function for strings - auto-detects HTML vs URL/path
function load(win::Window, content::AbstractString)
    # If it looks like HTML content (contains tags), treat as HTML
    if occursin(r"<\w+.*?>"s, content)
        return load(win, URI("data:text/html;charset=utf-8," * escapeuri(content)))
    else
        # Otherwise treat as URL/file path
        return load(win, URI(content))
    end
end

"""
    close(win::Window)

Close the window and clean up resources.
"""
function Base.close(win::Window)
    isopen(win) || throw(WindowClosedError(win.id, "close"))

    message = OptDict("cmd" => "closewindow", "winid" => win.id)
    retval = req_response(win.app, message)

    if haskey(retval, "error")
        @warn "Error closing window: $(retval["error"])"
    end

    return nothing
end

"""
    isopen(win::Window) -> Bool

Check if the window is still open and functional.
"""
Base.isopen(win::Window) = win.exists

"""
    msgchannel(win::Window) -> Channel

Get the message channel for receiving messages from the window's renderer process.
This provides compatibility with the original Electron.jl messaging pattern.

# Examples
```julia-repl
julia> win = Window()
julia> ch = msgchannel(win)
julia> # In JavaScript: sendMessageToJulia("hello from JS")
julia> @async begin
           msg = take!(ch)
           @info "Received: \$msg"
       end
```
"""
msgchannel(win::Window) = win.msg_channel

"""
    toggle_devtools(win::Window)

Toggle the developer tools for the window. Useful for debugging.
"""
function toggle_devtools(win::Window)
    isopen(win) || throw(WindowClosedError(win.id, "toggle_devtools"))

    run(win.app, "require('electron').BrowserWindow.fromId($(win.id)).webContents.toggleDevTools()")
end

# Helper functions

function apply_security_defaults!(options::Dict, security_config::SecurityConfig)
    # Ensure webPreferences exists
    if !haskey(options, "webPreferences")
        options["webPreferences"] = Dict{String,Any}()
    end

    web_prefs = options["webPreferences"]

    # Apply security configuration, but don't override user-specified values
    if !haskey(web_prefs, "contextIsolation")
        web_prefs["contextIsolation"] = security_config.context_isolation
    end

    if !haskey(web_prefs, "sandbox")
        web_prefs["sandbox"] = security_config.sandbox
    end

    if !haskey(web_prefs, "nodeIntegration")
        web_prefs["nodeIntegration"] = security_config.node_integration
    end

    if !haskey(web_prefs, "webSecurity")
        web_prefs["webSecurity"] = security_config.web_security
    end

    # Set preload script if specified
    if security_config.preload_script !== nothing && !haskey(web_prefs, "preload")
        preload_path = normpath(joinpath(asset_dir(), security_config.preload_script))
        if isfile(preload_path)
            web_prefs["preload"] = preload_path
        else
            @warn "Preload script not found: $preload_path"
        end
    end

    # Validate configuration
    if get(web_prefs, "nodeIntegration", false) && get(web_prefs, "sandbox", false)
        throw(
            SecurityError(
                "Cannot enable nodeIntegration with sandbox mode",
                "window_creation",
            ),
        )
    end
end

# ElectronAPI compatibility shim for Electron.jl parity

"""
    ElectronAPI

A shim object for calling Electron API functions directly on windows.
Provides compatibility with Electron.jl's ElectronAPI pattern.

See:
* <https://electronjs.org/docs/api/browser-window>

# Examples
```julia
julia> using ElectronCall

julia> win = Window();

julia> ElectronAPI.setBackgroundColor(win, "#000");

julia> ElectronAPI.show(win);
```
"""
ElectronAPI

struct ElectronAPIType end
const ElectronAPI = ElectronAPIType()

struct ElectronAPIFunction <: Function
    name::Symbol
end

Base.getproperty(::ElectronAPIType, name::Symbol) = ElectronAPIFunction(name)

function (api::ElectronAPIFunction)(w::Window, args...)
    name = api.name
    json_args = JSON.json(collect(args))
    run(w.app, "require('electron').BrowserWindow.fromId($(w.id)).$name(...$json_args)")
end
