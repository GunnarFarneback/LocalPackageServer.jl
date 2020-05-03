using Pkg

abstract type StorageServer end

struct PkgStorageServer <: StorageServer
    url::String
end

mutable struct GitStorageServer <: StorageServer
    url::String
    uuid::String
end

GitStorageServer(url) = GitStorageServer(url, "")

mutable struct Config
    host::String
    port::Int
    storage_servers::Vector{StorageServer}
    cache_dir::String
    git_clones_dir::String
    min_time_between_registry_updates::Int
    gitconfig::Dict{String, String}
end

function Config(filename::String)
    return Config(Pkg.TOML.parsefile(filename))
end

function Config(data::Dict)
    host = get(data, "host", "localhost")
    port = get(data, "port", 8000)
    if port isa String
        port = parse(Int, port)
    end
    local_registry = get(data, "local_registry", nothing)
    pkg_server = get(data, "pkg_server", nothing)
    cache_dir = get(data, "cache_dir", nothing)
    git_clones_dir = get(data, "git_clones_dir", nothing)
    t = get(data, "min_time_between_registry_updates", 60)
    gitconfig = get(data, "gitconfig", Dict{String, String}())

    storage_servers = Union{GitStorageServer, PkgStorageServer}[]
    if !isnothing(local_registry)
        push!(storage_servers, GitStorageServer(local_registry))
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
                  t, gitconfig)
end
