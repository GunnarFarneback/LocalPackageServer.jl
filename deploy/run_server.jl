using LocalPackageServer

config = Dict(
    # Server parameters
    "host" => "0.0.0.0",
    "port" => 8000,

    # This is where persistent data will be stored
    "cache_dir"      => abspath("/app/storage/cache"),
    "git_clones_dir" => abspath("/app/storage/data"),
)

# Package server to be used for non-local packages
# If none is provided, use pkg.julialang.org
config["pkg_server"] = get(ENV, "JULIA_PKG_SERVER", "https://pkg.julialang.org")

# Min time between checking registries for updates (default: 1 minute)
config["min_time_between_registry_updates"] = parse(Int, get(ENV, "MIN_TIME_BETWEEN_REGISTRY_UPDATES", "60"))

# Local registry: if none is provided LocalPackageServer turns into a storage
# server only
if "JULIA_LOCAL_REGISTRY" in keys(ENV)
    config["local_registry"] = ENV["JULIA_LOCAL_REGISTRY"]
else
    @warn "No local registry provided; behaving as a storage server."
end

@info("Local package server configuration:",
      pkg_server = config["pkg_server"],
      local_registry = get(config, "local_registry", "<STORAGE SERVER ONLY>"),
      min_time_between_registry_updates = config["min_time_between_registry_updates"],
      )

LocalPackageServer.start(LocalPackageServer.Config(config))
