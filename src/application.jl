# Application management for ElectronCall.
#
# Handles Electron application lifecycle, process management, and security configuration.

const OptDict = Dict{String,Any}

"""
    get_electron_binary_cmd() -> String

Get the path to the Electron binary executable.

This function provides compatibility with Electron.jl's API and returns
the path to the electron executable provided by Electron_jll.

# Examples
```julia
julia> path = get_electron_binary_cmd()
"/path/to/electron"
```
"""
function get_electron_binary_cmd()
    return Electron_jll.electron_path
end

# Application struct is forward declared in ElectronCall.jl
# Define the fields and internal constructor here
function Application(
    connection::IO,
    proc::Base.Process,
    secure_cookie::Vector{UInt8},
    security_config::SecurityConfig,
    name::String,
)
    app = Application(
        connection,
        proc,
        secure_cookie,
        Window[],
        true,
        security_config,
        name,
        ReentrantLock(),  # Initialize communication lock
    )
    push!(_global_applications, app)
    return app
end

function Base.show(io::IO, app::Application)
    if app.exists
        if length(app.windows) == 1
            appstate = ", [1 window])"
        else
            appstate = ", [$(length(app.windows)) windows])"
        end
    else
        appstate = ", [dead])"
    end
    print(io, "Application(\"$(app.name)\", ", app.connection, ", ", app.proc, appstate)
end

"""
    Application(; kwargs...) -> Application

Create a new Electron application with modern security defaults.

# Keywords
- `name::String = "ElectronCall-App"`: Application name
- `security::SecurityConfig = secure_defaults()`: Security configuration
- `development_mode::Bool = false`: Enable development features
- `additional_electron_args::Vector{String} = String[]`: Additional Electron arguments
- `main_js::String = default_main_js_path()`: Path to main.js file

# Examples
```julia
# Secure application with defaults
app = Application()

# Development application
app = Application(
    development_mode = true,
    security = development_config()
)

# Custom security configuration
app = Application(
    security = SecurityConfig(sandbox = false),
    additional_electron_args = ["--enable-logging", "--v=1"]
)
```
"""
function Application(;
    name::String = "ElectronCall-App",
    security::SecurityConfig = secure_defaults(),
    development_mode::Bool = false,
    additional_electron_args::Vector{String} = String[],
    main_js::String = default_main_js_path(),
    verbose::Bool = false,
)
    @assert isfile(main_js) "Main.js file not found: $main_js"

    # Adjust security for development mode
    if development_mode && security === secure_defaults()
        security = development_config()
        verbose && @info "Using development security configuration (some features disabled for debugging)"
    end

    # Validate security configuration
    validate_security_config(security, verbose)

    # Get the Electron binary path
    electron_path = get_electron_binary_cmd()

    # Generate unique identifiers for named pipes
    id = replace(string(uuid1()), "-" => "")
    main_pipe_name = generate_pipe_name("elcall-$id")
    sysnotify_pipe_name = generate_pipe_name("elcall-sn-$id")

    # Set up named pipe servers
    server = listen(main_pipe_name)
    sysnotify_server = listen(sysnotify_pipe_name)

    # Generate secure authentication cookie
    secure_cookie = rand(UInt8, 128)
    secure_cookie_encoded = base64encode(secure_cookie)

    # Build Electron command with security-conscious defaults
    # Electron flags must come before the main.js file
    electron_cmd_args = [electron_path]

    # Add sandbox control - default is enabled (opposite of original Electron.jl)
    if !security.sandbox
        push!(electron_cmd_args, "--no-sandbox")
        verbose && @warn "Sandbox disabled - this reduces security. Only disable for development/debugging."
    end

    # Add custom electron arguments (before main.js)
    append!(electron_cmd_args, additional_electron_args)

    # Add main.js and application arguments
    append!(electron_cmd_args, [
        main_js,
        main_pipe_name,
        sysnotify_pipe_name,
        secure_cookie_encoded,
        base64encode(JSON.json(security)),  # Pass security config to main.js
    ])

    electron_cmd = Cmd(electron_cmd_args)

    # Clean environment
    new_env = copy(ENV)
    if haskey(new_env, "ELECTRON_RUN_AS_NODE")
        delete!(new_env, "ELECTRON_RUN_AS_NODE")
    end

    # Start Electron process
    try
        proc = open(Cmd(electron_cmd, env = new_env), "w", stdout)

        # Accept connections with timeout
        sock = accept(server)
        sysnotify_sock = accept(sysnotify_server)

        # Authenticate connections
        if read!(sock, zero(secure_cookie)) != secure_cookie
            close.([server, sysnotify_server, sock, sysnotify_sock])
            error("Electron failed to authenticate with proper security token")
        end

        if read!(sysnotify_sock, zero(secure_cookie)) != secure_cookie
            close.([server, sysnotify_server, sock, sysnotify_sock])
            error("Electron failed to authenticate with proper security token")
        end

        close.([server, sysnotify_server])

        # Create application instance
        app = Application(sock, proc, secure_cookie, security, name)

        # Start async notification handler
        @async handle_notifications(app, sysnotify_sock)

        return app

    catch e
        close.([server, sysnotify_server])
        if e isa InterruptException
            rethrow(e)
        end
        error_msg = sprint(showerror, e)
        rethrow(ApplicationError("Failed to start Electron application: $error_msg", nothing))
    end
end

"""
    close(app::Application)

Gracefully shut down the Electron application and all its windows.
"""
function Base.close(app::Application)
    app.exists || error("Cannot close application - already closed")

    # Close all windows first
    while length(app.windows) > 0
        close(first(app.windows))
    end

    app.exists = false
    close(app.connection)

    # Remove from global applications list
    app_index = findfirst(a -> a === app, _global_applications)
    if app_index !== nothing
        deleteat!(_global_applications, app_index)
    end
end

# Helper functions

function generate_pipe_name(name::String)
    return if Sys.iswindows()
        "\\\\.\\pipe\\$name"
    elseif Sys.isunix()
        joinpath(tempdir(), name)
    end
end

# Directory holding the JS assets (main.js, preload.js), resolved at RUNTIME.
# We must not use @__DIR__: it bakes the precompile-time source path into the
# compiled image, so in a relocatable app bundle (precompiled in a build dir,
# run from /opt, a snap mount, /tmp, …) it points at a path that no longer
# exists. pkgdir() is relocation-aware and returns the actual load location.
function asset_dir()
    dir = pkgdir(@__MODULE__)
    dir === nothing && error("ElectronCall: cannot locate package directory to resolve JS assets")
    return joinpath(dir, "src")
end

function default_main_js_path()
    return normpath(joinpath(asset_dir(), "main.js"))
end

function validate_security_config(config::SecurityConfig, verbose::Bool=true)
    # Warn about insecure configurations
    if config.node_integration && config.context_isolation
        verbose && @warn "node_integration=true with context_isolation=true may not work as expected"
    end

    if !config.context_isolation && !config.sandbox
        verbose && @warn "Disabling both context_isolation and sandbox creates significant security risks"
    end

    # Electron automatically disables sandbox when nodeIntegration is enabled
    # See: https://www.electronjs.org/docs/latest/tutorial/sandbox
    if config.node_integration && config.sandbox
        throw(
            SecurityError(
                "Cannot enable node_integration with sandbox=true. " *
                "Electron automatically disables the sandbox when nodeIntegration is enabled. " *
                "Set sandbox=false explicitly or disable node_integration.",
                "configuration",
            ),
        )
    end
end

"""
Handle system notifications from Electron process.
"""
function handle_notifications(app::Application, sysnotify_sock::IO)
    try
        while app.exists
            try
                line_json = readline(sysnotify_sock)
                isempty(line_json) && break  # EOF

                cmd_parsed = JSON.parse(line_json)

                if cmd_parsed["cmd"] == "windowclosed"
                    handle_window_closed(app, cmd_parsed["winid"])
                elseif cmd_parsed["cmd"] == "appclosing"
                    break
                elseif cmd_parsed["cmd"] == "msg_from_window"
                    handle_window_message(app, cmd_parsed["winid"], cmd_parsed["payload"])
                elseif cmd_parsed["cmd"] == "error"
                    @error "Electron process error: $(cmd_parsed["message"])"
                end
            catch err
                if app.exists  # Only log errors if app is still active
                    @error "Error processing notification" exception = err
                end
            end
        end
    finally
        # Cleanup
        for w in app.windows
            w.exists = false
        end
        empty!(app.windows)
        app.exists = false
        close(sysnotify_sock)
    end
end

function handle_window_closed(app::Application, winid::Int)
    win_index = findfirst(w -> w.id == winid, app.windows)
    if win_index !== nothing
        app.windows[win_index].exists = false
        close(app.windows[win_index].msg_channel)
        deleteat!(app.windows, win_index)
    end
end

function handle_window_message(app::Application, winid::Int, payload)
    win_index = findfirst(w -> w.id == winid, app.windows)
    if win_index !== nothing
        put!(app.windows[win_index].msg_channel, payload)
    end
end
