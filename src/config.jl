using TOML

abstract type StorageServer end

struct PkgStorageServer <: StorageServer
    url::String
end

mutable struct GitStorageServer <: StorageServer
    url::String
    uuid::String
    registry_dir::String
end

# Legacy format: single `local_registry`
GitStorageServer(url) = GitStorageServer(url, "", "registry")

# New format: `local_registries` table
GitStorageServer(url, uuid) = GitStorageServer(url, uuid, joinpath("registries", uuid))

function registry_url(url::AbstractString)
    url = convert(String, strip(url))::String
    if isempty(url)
        error("Registry URL must not be empty.")
    end
    return url
end

# `local_registries` maps registry UUID to registry URL
function registry_table(local_registries::AbstractDict)
    registries = Dict{String, String}()
    for (uuid, url) in local_registries
        uuid = convert(String, strip(uuid))::String
        if !occursin(Regex("^$(uuid_re)\$"), uuid)
            error("Invalid registry UUID in `local_registries`: ", repr(uuid))
        end
        registries[uuid] = registry_url(url)
    end
    return registries
end

mutable struct Config
    host::String
    port::Int
    storage_servers::Vector{StorageServer}
    cache_dir::String
    git_clones_dir::String
    min_time_between_registry_updates::Int
    repository_clone_strategy::Symbol
    log_format::Symbol
    gitconfig::Dict{String, String}
end

function Config(filename::String)
    return Config(TOML.parsefile(filename))
end

function Config(data::Dict)
    host = get(data, "host", "localhost")
    port = get(data, "port", 8000)
    if port isa String
        port = parse(Int, port)
    end
    local_registry = get(data, "local_registry", nothing)
    local_registries = get(data, "local_registries", nothing)
    if !isnothing(local_registry) && !isnothing(local_registries)
        error("Only one of `local_registry` and `local_registries` can be specified.")
    end
    pkg_server = get(data, "pkg_server", nothing)
    cache_dir = get(data, "cache_dir", nothing)
    git_clones_dir = get(data, "git_clones_dir", nothing)
    min_time = get(data, "min_time_between_registry_updates", 60)
    s = get(data, "repository_clone_strategy", "on_failure")
    strategies = ["always", "on_failure", "if_missing"]
    if s in strategies
        strategy = Symbol(s)
    else
        error("Unknown repository_clone_strategy: $s\n",
              "Valid options are ", join(strategies, ", "), ".")
    end
    f = get(data, "log_format", "text")
    log_formats = ["text", "json"]
    if f in log_formats
        log_format = Symbol(f)
    else
        error("Unknown log_format: $f\n",
              "Valid options are ", join(log_formats, ", "), ".")
    end
    gitconfig = get(data, "gitconfig", Dict{String, String}())

    storage_servers = Union{GitStorageServer, PkgStorageServer}[]
    if !isnothing(local_registry)
        # Legacy format: single `local_registry`
        push!(storage_servers, GitStorageServer(registry_url(local_registry)))
    end
    if !isnothing(local_registries)
        # New format: `local_registries` table
        registries = registry_table(local_registries)
        for uuid in sort!(collect(keys(registries)))
            push!(storage_servers, GitStorageServer(registries[uuid], uuid))
        end
    end
    if !isnothing(pkg_server)
        push!(storage_servers, PkgStorageServer(pkg_server))
    end
    if isempty(storage_servers)
        error("No package source configured.")
    end
    if isnothing(cache_dir)
        error("cache_dir must be configured.")
    end
    if isnothing(git_clones_dir)
        error("git_clones_dir must be configured.")
    end
    cache_dir = rstrip(cache_dir, ['/', '\\'])
    git_clones_dir = rstrip(git_clones_dir, ['/', '\\'])

    return Config(host, port, storage_servers, cache_dir, git_clones_dir,
                  min_time, strategy, log_format, gitconfig)
end
