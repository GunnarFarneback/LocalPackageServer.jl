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

cache_path(config, resource) = config.cache_dir * resource
tempfilename(path) = path * ".inprogress"

"""
    write_atomic(f::Function, path::String)

Performs an atomic filesystem write by writing out to a file on the same
filesystem as the given `path`, then `move()`'ing the file to its eventual
destination.  Requires write access to the file and the containing folder.
Currently stages changes at "<path>.tmp.<randstring>".  If the return value
of `f()` is `false` or an exception is raised, the write will be aborted.
"""
function write_atomic(f::Function, path::String)
    temp_file = tempfilename(path)
    try
        retval = open(temp_file, "w") do io
            f(temp_file, io)
        end
        if retval !== false
            mv(temp_file, path; force=true)
        end
        return retval
    catch e
        rethrow(e)
    finally
        if isfile(temp_file)
            rm(temp_file; force=true)
        end
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

mutable struct ContentState
    length::Int
end
ContentState() = ContentState(-1)

struct FetchState
    resource::String
    content::ContentState
    task::Task
end

struct FetchInProgress
    state::FetchState
    io::IOStream
end

const fetch_lock = ReentrantLock()
const fetches_in_progress = Dict{String, FetchState}()
# If this resource is already available as file in the cache, return
# the filename. Otherwise return a `FetchInProgress` object.
#
# The idea is that `serve_file` will dispatch to regular file serving
# or a streaming serve of the ongoing fetch depending on what is
# returned from this function.
#
# To avoid race conditions, we keep a list of ongoing fetches, which
# can only be read or updated while holding a lock.
#
# This function also implements the `atomic_write` strategy of first
# writing to a temporary file, then renaming it after it's complete.
function cached_fetch_resource(config::Config, resource::AbstractString)
    # The `/registries` resource is special since it needs to be
    # updated periodically.
    resource == "/registries" && update_registries(config)
    path = cache_path(config, resource)
    isfile(path) && return path
    return lock(fetch_lock) do
        temp_file = tempfilename(path)
        state = get!(fetches_in_progress, resource) do
            mkpath(dirname(temp_file))
            io = open(temp_file, "w")
            content = ContentState()
            task = @async begin
                success = fetch_resource(config, resource, io, content)
                close(io)
                # Note: This lock call is not nested within the outer
                # lock call but happens in a separate task.
                lock(fetch_lock) do
                    if success
                        mkpath(dirname(path))
                        mv(temp_file, path, force = true)
                    end
                    delete!(fetches_in_progress, resource)
                end
            end
            # Return from do block, not from function.
            return FetchState(resource, content, task)
        end
        # Return from do block, not from function.
        return FetchInProgress(state, open(temp_file, "r"))
    end
end

function fetch_resource(config::Config, resource::AbstractString, io::IOStream,
                        content::ContentState)
    servers = config.storage_servers
    for server in servers
        if download(config, server, resource, io, content)
            return true
        end
        if content.length >= 0
            break
        end
    end
    @warn "download failed" resource=resource  Dates.now()
    return false
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
                  io::IOStream, content::ContentState)
    @info "downloading resource" server=server resource=resource Dates.now()
    hash = let m = match(hash_part_re, resource)
        m !== nothing ? m.captures[1] : nothing
    end

    if !get_resource_from_storage_server!(config, server, resource,
                                          io, content)
        return false
    end

    # If we're given a hash, then check tarball git hash.
    if hash !== nothing
        temp_file = tempfilename(cache_path(config, resource))
        tree_hash = tarball_git_hash(temp_file)
        # Raise warnings about resource hash mismatches
        if hash != tree_hash
            @warn "resource hash mismatch" server=server resource=resource hash=tree_hash Dates.now()
            return false
        end
    end

    return true
end

function content_length(response::HTTP.Messages.Response)
    for h in response.headers
        if lowercase(h[1]) == "content-length"
            return parse(Int, h[2])
        end
    end
    return nothing
end

function get_resource_from_storage_server!(config, server::PkgStorageServer,
                                           resource, io::IOStream,
                                           content::ContentState)
    response = HTTP.head(server.url * resource, status_exception = false)
    # Raise warnings about bad HTTP response codes
    if response.status != 200
        @warn "response status $(response.status)" Dates.now()
        return false
    end
    content.length = content_length(response)

    response = HTTP.get(server.url * resource,
                        status_exception = false,
                        response_stream = io)
    close(io)

    if response.status != 200
        @warn "response status $(response.status)" Dates.now()
        return false
    end

    return true
end

function serve_file(http::HTTP.Stream, path::String, content_type::AbstractString)
    HTTP.setheader(http, "Content-Length" => string(filesize(path)))
    HTTP.setheader(http, "Content-Type" => content_type)
    startwrite(http)

    # Only write the headers for HEAD requests, not the file content.
    http.message.method == "HEAD" && return true

    # Open the path, write it out directly to the HTTP stream
    open(io -> write(http, read(io, String)), path)
    return true
end

function serve_file(http::HTTP.Stream, in_progress::FetchInProgress,
                    content_type::AbstractString)
    buffer = Vector{UInt8}(undef, 2 * 1024 * 1024)
    transmitted = 0
    length = typemax(Int)
    while transmitted < length
        n = readbytes!(in_progress.io, buffer)
        if n == 0
            if !istaskdone(in_progress.state.task)
                sleep(0.1)
            else
                break
            end
        else
            if transmitted == 0
                length = in_progress.state.content.length
                HTTP.setheader(http, "Content-Length" => string(length))
                HTTP.setheader(http, "Content-Type" => content_type)
                HTTP.startwrite(http)
                # Only write the headers for HEAD requests, not the
                # file content.
                if http.message.method == "HEAD"
                    return true
                end
            end
            try
                transmitted += write(http, view(buffer, 1:min(n, length - transmitted)))
            catch e
                # If the client disappears, just silently early-exit
                if isa(e, Base.IOError) && e.code in (-Base.Libc.EPIPE, -Base.Libc.ECONNRESET)
                    close(in_progress.io)
                    return true
                end
                rethrow(e)
            end
        end
    end

    close(in_progress.io)

    if in_progress.state.content.length < 0
        return false
    end

    if transmitted < length
        return false
    end

    return true
end
