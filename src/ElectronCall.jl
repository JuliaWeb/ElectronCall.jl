module ElectronCall

using JSON, URIs, Sockets, Base64, Electron_jll, UUIDs

# Core exports - clean, minimal API inspired by Electron.jl
export Application, Window, URI, windows, applications, msgchannel, load
export close, isopen, default_application
export toggle_devtools, ElectronAPI, get_electron_binary_cmd

# Modern async exports
export @async_app, @js, @window, @electron_function, SecurityConfig

# Error types
export ElectronCallError, JSExecutionError, WindowClosedError, SecurityError

# Include core modules in dependency order
include("security.jl")
include("errors.jl")

# Forward declare types to break circular dependency
mutable struct Application
    connection::IO
    proc::Base.Process
    secure_cookie::Vector{UInt8}
    windows::Vector{Any}  # Use Any to avoid forward reference issue
    exists::Bool
    security_config::SecurityConfig
    name::String
    comm_lock::ReentrantLock  # Prevent race conditions in concurrent req_response calls
end

mutable struct Window
    app::Application
    id::Int64
    exists::Bool
    msg_channel::Channel{Any}
end

include("application.jl")
include("window.jl")
include("communication.jl")
include("macros.jl")

# Global state management
const _global_applications = Vector{Application}(undef, 0)
const _global_default_application = Ref{Union{Nothing,Application}}(nothing)

function __init__()
    atexit() do
        # Graceful shutdown of all applications
        for app in _global_applications
            if app.exists
                close(app)
            end
        end
    end
    nothing
end

"""
    applications()

Return a vector of all currently active Electron applications.
"""
applications() = _global_applications

"""
    windows(app::Application)

Return a vector of all windows associated with the given application.
"""
windows(app::Application) = app.windows

"""
    default_application()

Get or create the default Electron application. This provides compatibility
with the original Electron.jl pattern where users don't need to manage
Application objects explicitly.
"""
function default_application(security::SecurityConfig = secure_defaults())
    if _global_default_application[] === nothing ||
       _global_default_application[].exists == false
        _global_default_application[] = Application(security = security)
    end
    return _global_default_application[]
end

include("testing.jl")

end # module ElectronCall
