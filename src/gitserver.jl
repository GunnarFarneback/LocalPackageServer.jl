using Pkg
using CodecZlib

function gitcmd(config, path)
    cmd = ["git", "-C", path]
    for (key, value) in config.gitconfig
        push!(cmd, "-c")
        push!(cmd, "$(key)=$(value)")
    end
    return Cmd(cmd)
end

function get_local_registry_dir(config)
    dir = joinpath(config.git_clones_dir, "registry")
    return dir
end

function get_local_package_dir(config, uuid)
    dir = joinpath(config.git_clones_dir, "packages", uuid)
    return dir
end

function get_registries(config, server::GitStorageServer)
    repo = server.url
    registry_dir = get_local_registry_dir(config)
    git = gitcmd(config, registry_dir)
    if !isdir(registry_dir)
        mkpath(registry_dir)
        run(`$git clone $(repo) .`)
    else
        run(`$git pull --quiet`)
    end
    registry = Pkg.TOML.parsefile(joinpath(registry_dir, "Registry.toml"))
    server.uuid = registry["uuid"]
    hash = readchomp(`$git rev-parse --verify HEAD:`)
    return Dict(registry["uuid"] => hash)
end

function get_resource_from_storage_server!(config, server::GitStorageServer,
                                           resource, io, content::ContentState)
    # Need to be conservative and update the registry in case
    # something has changed. New packages may have appeared or an
    # existing package could have a new URL.
    get_registries(config, server)

    parts = split(resource, "/", keepempty = false)
    registry_dir = get_local_registry_dir(config)
    if parts[1] == "registry"
        git = gitcmd(config, registry_dir)
        uuid = parts[2]
        hash = parts[3]
        uuid != server.uuid && return false
    elseif parts[1] == "package"
        uuid = parts[2]
        hash = parts[3]
        # TODO: Cache Registry.toml in memory.
        registry = Pkg.TOML.parsefile(joinpath(registry_dir, "Registry.toml"))
        haskey(registry["packages"], uuid) || return false
        package_dir = joinpath(registry_dir, registry["packages"][uuid]["path"])
        package = Pkg.TOML.parsefile(joinpath(package_dir, "Package.toml"))
        repo = package["repo"]
        local_package_dir = get_local_package_dir(config, uuid)
        git = gitcmd(config, local_package_dir)
        if !isdir(local_package_dir)
            @info "Cloning package" repo=repo Dates.now()
            mkpath(local_package_dir)
            try
                run(`$git clone --mirror $(repo) .`)
            catch e
                @info "Failed to clone $(repo)."
                rm(local_package_dir, recursive = true)
                rethrow(e)
            end
        else
            # If hash is not available, update git repo.
            try
                run(`$git rev-parse --verify --quiet $(hash)^\{tree\}`)
            catch
                @info "Hash not available, updating from remote" repo=repo hash=hash Dates.now()
                run(`$git remote update`)
            end
            # Still not there? Nothing to do about it.
            try
                run(`$git rev-parse --verify --quiet $(hash)^\{tree\}`)
            catch
                @error "Hash still not available after remote update" repo=repo hash=hash Dates.now()
                close(io)
                return false
            end
        end
    elseif parts[1] == "artifact"
        @info "No support for artifacts" Dates.now()
        return false
    else
        @info "Unknown resource $(parts[1])" Dates.now()
        return false
    end

    # Do not allow git on windows to convert line endings in the tarball.
    tar = read(`$git -c core.autocrlf=false archive $(hash)`)
    gzip = transcode(GzipCompressor, tar)
    content.length = length(gzip)
    write(io, gzip)
    close(io)
    return true
end
