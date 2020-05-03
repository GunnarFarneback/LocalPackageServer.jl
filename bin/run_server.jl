#!/usr/bin/env julia

using LocalPackageServer
using LocalPackageServer: PkgStorageServer, GitStorageServer, Config

if isempty(ARGS)
    println("Usage: run_server.jl config.toml")
else
    LocalPackageServer.start(ARGS[1])
end
