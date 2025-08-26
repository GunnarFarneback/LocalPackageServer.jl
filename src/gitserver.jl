using TOML
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

function read_registry_toml(git, toml_path)
    registry_toml = read(`$git cat-file blob @:$(toml_path)`, String)
    return TOML.parse(registry_toml)
end

function get_registries(config, server::GitStorageServer)
    repo = server.url
    registry_dir = get_local_registry_dir(config)
    if isdir(joinpath(registry_dir, ".git"))
        # Upgrade from LocalPackageServer 0.1.x, which used a clone
        # with workspace.
        rm(registry_dir, recursive = true)
    end
    clone_or_update_repository(config, registry_dir, repo)
    git = gitcmd(config, registry_dir)
    registry = read_registry_toml(git, "Registry.toml")
    server.uuid = registry["uuid"]
    hash = readchomp(`$git rev-parse --verify HEAD:`)
    return Dict(registry["uuid"] => hash)
end

function clone_repository(git, repo, path)
    rm(path, recursive = true, force = true)
    @info "Cloning repository" repo=repo Dates.now()
    mkpath(path)
    try
        run(`$git clone --mirror $(repo) $(path)`)
    catch e
        @error "Failed to clone $(repo)." error=e
        rm(path, recursive = true, force = true)
        rethrow(e)
    end
end

# Clone or update a repository according to
# config.repository_clone_strategy.
function clone_or_update_repository(config, path, repo, hash = nothing)
    clone_strategy = config.repository_clone_strategy
    git = gitcmd(config, path)
    if clone_strategy == :always || !isdir(path)
        clone_repository(git, repo, path)
    else
        # If hash is not available or no hash was provided, update git
        # repo.
        update_needed = false
        if isnothing(hash)
            update_needed = true
        else
            try
                read(`$git rev-parse --verify --quiet $(hash)^\{tree\}`)
            catch e
                @info "Hash not available, updating from remote" repo=repo hash=hash Dates.now()
                update_needed = true
            end
        end
        if update_needed
            try
                run(`$git remote update`)
            catch e
                @error "Failed to update $(repo)." error = e
                if clone_strategy == :on_failure
                    clone_repository(git, repo, path)
                end
            end
        end
    end
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
        registry_git = gitcmd(config, registry_dir)
        uuid = parts[2]
        hash = parts[3]
        # TODO: Cache Registry.toml in memory.
        registry = read_registry_toml(registry_git, "Registry.toml")
        haskey(registry["packages"], uuid) || return false
        package_toml = registry["packages"][uuid]["path"] * "/" * "Package.toml"
        package = read_registry_toml(registry_git, package_toml)
        repo = package["repo"]
        local_package_dir = get_local_package_dir(config, uuid)
        clone_or_update_repository(config, local_package_dir, repo, hash)
        git = gitcmd(config, local_package_dir)
    elseif parts[1] == "artifact"
        @info "No support for artifacts" Dates.now()
        return false
    else
        @info "Unknown resource $(parts[1])" Dates.now()
        return false
    end

    try
        read(`$git rev-parse --verify --quiet $(hash)^\{tree\}`)
    catch
        @error "Hash not available in repository" repo=repo hash=hash Dates.now()
        close(io)
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
