# Utilities to deal with fetching/serving actual Pkg resources

const uuid_re = raw"[0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12}(?-i)"
const hash_re = raw"[0-9a-f]{40}"
const meta_re     = Regex("^/meta\$")
const registry_re = Regex("^/registry/($uuid_re)/($hash_re)\$")
const resource_re = Regex("""
    ^/registries\$
  | ^/registry/$uuid_re/$hash_re\$
  | ^/package/$uuid_re/$hash_re\$
  | ^/artifact/$hash_re\$
""", "x")
const hash_part_re = Regex("/($hash_re)\$")

function get_registries(config, server::PkgStorageServer)
    regs = Dict{String, String}()
    response = HTTP.get("$(server.url)/registries")
    for line in eachline(IOBuffer(response.body))
        m = match(registry_re, line)
        if m !== nothing
            uuid, hash = m.captures
            regs[uuid] = hash
        else
            @error "invalid response" server=server.url resource="/registries" line=line Dates.now()
        end
    end
    return regs
end


"""
    write_atomic(f::Function, path::String)

Performs an atomic filesystem write by writing out to a file on the same
filesystem as the given `path`, then `move()`'ing the file to its eventual
destination.  Requires write access to the file and the containing folder.
Currently stages changes at "<path>.tmp.<randstring>".  If the return value
of `f()` is `false` or an exception is raised, the write will be aborted.
"""
function write_atomic(f::Function, path::String)
    temp_file = path * ".tmp." * randstring()
    try
        retval = open(temp_file, "w") do io
            f(temp_file, io)
        end
        if retval !== false
            mv(temp_file, path; force=true)
        end
        return retval
    catch e
        rm(temp_file; force=true)
        rethrow(e)
    end
end

# Current registry hashes.
const REGISTRY_HASHES = Dict{String,String}()

const last_registry_update = Ref{Float64}(0)

function update_registries(config)
    t = time()
    if t < last_registry_update[] + config.min_time_between_registry_updates
        return
    end

    changed = false
    # Collect current registry hashes from servers.
    for server in config.storage_servers
        for (uuid, hash) in get_registries(config, server)
            if get(REGISTRY_HASHES, uuid, "") != hash
                REGISTRY_HASHES[uuid] = hash
                changed = true
            end
        end
    end

    # Write new registry info to file.
    if changed
        write_atomic(joinpath(config.cache_dir, "registries")) do temp_file, io
            for uuid in sort!(collect(keys(REGISTRY_HASHES)))
                hash = REGISTRY_HASHES[uuid]
                println(io, "/registry/$uuid/$hash")
            end
            return true
        end
    end
    last_registry_update[] = t
    return
end

function fetch(config::Config, resource::AbstractString)
    resource == "/registries" && update_registries(config)
    path = config.cache_dir * resource
    isfile(path) && return path
    update_registries(config)
    servers = config.storage_servers
    isempty(servers) && throw(@error "fetch called with no servers" resource=resource)

    mkpath(dirname(path))
    for server in servers
        if download(config, server, resource, path)
            break
        end
    end
    success = isfile(path)
    success || @warn "download failed" resource=resource  Dates.now()
    return success ? path : nothing
end

function tarball_git_hash(tarball::String)
    local tree_hash
    mktempdir() do tmp_dir
        open(tarball) do io
            Tar.extract(GzipDecompressorStream(io), tmp_dir)
        end
        tree_hash = bytes2hex(Pkg.GitTools.tree_hash(tmp_dir))
        chmod(tmp_dir, 0o777, recursive = true)
    end
    return tree_hash
end

function download(config, server::StorageServer, resource::AbstractString,
                  path::AbstractString)
    @info "downloading resource" server=server resource=resource Dates.now()
    hash = let m = match(hash_part_re, resource)
        m !== nothing ? m.captures[1] : nothing
    end

    write_atomic(path) do temp_file, io
        if !get_resource_from_storage_server!(config, server, resource, io)
            return false
        end

        # If we're given a hash, then check tarball git hash
        if hash !== nothing
            tree_hash = tarball_git_hash(temp_file)
            # Raise warnings about resource hash mismatches
            if hash != tree_hash
                @warn "resource hash mismatch" server=server resource=resource hash=tree_hash Dates.now()
                return false
            end
        end

        return true
    end
end

function get_resource_from_storage_server!(config, server::PkgStorageServer,
                                           resource, io)
    response = HTTP.get(status_exception = false,
                        response_stream = io,
                        server.url * resource)

    # Raise warnings about bad HTTP response codes
    if response.status != 200
        @warn "response status $(response.status)" Dates.now()
        return false
    end

    return true
end

function serve_file(http::HTTP.Stream, path::String)
    HTTP.setheader(http, "Content-Length" => string(filesize(path)))
    # We assume that everything we send is gzip-compressed (since they're all tarballs)
    HTTP.setheader(http, "Content-Encoding" => "gzip")
    startwrite(http)

    # Open the path, write it out directly to the HTTP stream
    open(io -> write(http, read(io, String)), path)
end
