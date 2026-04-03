# Security configuration and utilities for ElectronCall.
#
# Implements security-first design with context isolation, sandboxing,
# and configurable permissions.

"""
    SecurityConfig

Configuration for Electron security settings. Defaults to secure settings
that address the vulnerabilities in the original Electron.jl package.

# Fields
- `context_isolation::Bool`: Enable context isolation (default: true)
- `sandbox::Bool`: Enable sandbox mode (default: true)
- `node_integration::Bool`: Allow Node.js in renderer (default: false)
- `web_security::Bool`: Enable web security (default: true)
- `preload_script::Union{String,Nothing}`: Path to preload script
"""
struct SecurityConfig
    context_isolation::Bool
    sandbox::Bool
    node_integration::Bool
    web_security::Bool
    preload_script::Union{String,Nothing}

    function SecurityConfig(;
        context_isolation::Bool = true,
        sandbox::Bool = true,
        node_integration::Bool = false,
        web_security::Bool = true,
        preload_script::Union{String,Nothing} = nothing,
    )
        new(
            context_isolation,
            sandbox,
            node_integration,
            web_security,
            preload_script,
        )
    end
end

"""
    secure_defaults() -> SecurityConfig

Returns a SecurityConfig with secure defaults.
"""
secure_defaults() = SecurityConfig()

"""
    development_config() -> SecurityConfig

Returns a SecurityConfig suitable for development, with some security
features relaxed for debugging purposes.
"""
function development_config()
    SecurityConfig(
        context_isolation = true,
        sandbox = false,  # Disabled for easier debugging
        node_integration = false,
        web_security = true,
        preload_script = nothing,
    )
end

"""
    legacy_compatibility_config() -> SecurityConfig

Returns a SecurityConfig that mimics the original Electron.jl behavior.
⚠️  WARNING: This configuration has known security vulnerabilities and
should only be used for legacy compatibility during migration.
"""
function legacy_compatibility_config()
    @warn "Using legacy compatibility configuration with known security vulnerabilities. " *
          "This should only be used temporarily during migration from Electron.jl."
    SecurityConfig(
        context_isolation = false,  # ⚠️ INSECURE - matches Electron.jl
        sandbox = false,           # ⚠️ INSECURE - matches Electron.jl --no-sandbox
        node_integration = true,   # ⚠️ INSECURE - matches Electron.jl
        web_security = true,
        preload_script = nothing,
    )
end
