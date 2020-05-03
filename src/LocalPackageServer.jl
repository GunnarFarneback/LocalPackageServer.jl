module LocalPackageServer

using Pkg
using HTTP
using Random
using Tar

include("config.jl")
include("resource.jl")
include("meta.jl")
include("gitserver.jl")

function __init__()
    # Set default HTTP useragent
    HTTP.setuseragent!("LocalPackageServer (HTTP.jl)")
end

start(config) = start(Config(config))

function start(config::Config)
    host = config.host
    port = config.port
    mkpath(config.cache_dir)
    @info "server listening on $(host):$(port)"
    HTTP.listen(host, port) do http
        resource = http.message.target
        @show "start" resource
        # If the user is asking for `/meta`, generate the
        # requisite JSON object and send it back.
        if occursin(meta_re, resource)
            serve_meta(config, http)
            return
        end

        # If the user asked for something that is an actual
        # resource, send it directly.
        if occursin(resource_re, resource)
            path = fetch(config, resource)
            if path !== nothing
                serve_file(http, path)
                return
            end
        end
        HTTP.setstatus(http, 404)
        startwrite(http)
    end
end

end # module
