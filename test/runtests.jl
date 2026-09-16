using LocalPackageServer, LocalRegistry, Pkg, Test, Inflate
using LocalPackageServer: fetch_resource, cache_path, tempfilename
using LocalPackageServer: update_registries, ContentState
using LocalPackageServer: GitStorageServer, PkgStorageServer, Config

const TEST_GITCONFIG = Dict(
    "user.name" => "LocalRegistryTests",
    "user.email" => "localregistrytests@example.com"
)

# Simplified version of cached_fetch_resource which always returns the
# cached filename.
function fetch_test(config, resource)
    resource == "/registries" && update_registries(config)
    path = cache_path(config, resource)
    temp_file = tempfilename(path)
    isfile(path) && return path
    mkpath(dirname(path))
    open(temp_file, "w") do io
        fetch_resource(config, resource, io, ContentState())
    end
    mv(temp_file, path, force = true)
    return path
end

# Hook into the LocalRegistry testing infrastructure.
include(joinpath(dirname(dirname(pathof(LocalRegistry))), "test", "utils.jl"))

@testset "local registry configuration" begin
    uuid1 = "11111111-1111-1111-1111-111111111111"
    uuid2 = "22222222-2222-2222-2222-222222222222"
    url1 = "https://example.com/RegistryOne.git"
    url2 = "https://example.com/RegistryTwo.git"
    base = Dict{String, Any}("cache_dir" => "cache", "git_clones_dir" => "data")
    config(d) = Config(merge(base, Dict{String, Any}(d)))

    # Legacy format: single `local_registry`
    # Registry is cloned to `git_clones_dir/registry`
    servers = config(["local_registry" => url1]).storage_servers
    @test length(servers) == 1
    @test servers[1] isa GitStorageServer
    @test servers[1].url == url1
    @test servers[1].uuid == ""
    @test servers[1].registry_dir == "registry"

    # New format: `local_registries` table
    # Each registry is cloned to `git_clones_dir/registries/$uuid`
    servers = config(["local_registries" => Dict(uuid2 => url2, uuid1 => url1)]).storage_servers
    @test length(servers) == 2
    @test [s.uuid for s in servers] == [uuid1, uuid2]
    @test [s.url for s in servers] == [url1, url2]
    @test [s.registry_dir for s in servers] == [joinpath("registries", uuid1), joinpath("registries", uuid2)]

    # Local registries are still consulted before the package server.
    servers = config(["local_registries" => Dict(uuid1 => url1), "pkg_server" => "https://pkg.example.com"]).storage_servers
    @test servers[1] isa GitStorageServer
    @test servers[2] isa PkgStorageServer

    # Surrounding whitespace is not significant.
    servers = config(["local_registry" => " $(url1) "]).storage_servers
    @test servers[1].url == url1
    servers = config(["local_registries" => Dict(" $(uuid1) " => " $(url1) ")]).storage_servers
    @test servers[1].uuid == uuid1
    @test servers[1].url == url1

    # Erroneous configurations.
    @test_throws ErrorException config(["local_registry" => url1, "local_registries" => Dict(uuid1 => url1)])
    @test_throws MethodError config(["local_registries" => url1])
    @test_throws ErrorException config(["local_registries" => Dict("not a uuid" => url1)])
    @test_throws ErrorException config(["local_registries" => Dict(url1 => url1)])
    @test_throws MethodError config(["local_registries" => Dict(uuid1 => 17)])
    @test_throws ErrorException config(["local_registries" => Dict(uuid1 => "   ")])
    @test_throws ErrorException config(["local_registry" => "  "])
end

mktempdir(@__DIR__) do test_dir
    # Start by creating an empty registry.
    upstream_registry_dir = joinpath(test_dir, "upstream_registry.git")
    mkpath(upstream_registry_dir)
    run(`git -C $(upstream_registry_dir) init --bare`)
    registry_dir = joinpath(test_dir, "TestRegistry")
    packages_dir = joinpath(test_dir, "packages")
    upstream_registry_url = string("file://", upstream_registry_dir)
    registry_uuid = "ed6ca2f6-392d-11ea-3224-d3daf7fee369"
    create_registry(registry_dir, upstream_registry_url, push = true,
                    gitconfig = TEST_GITCONFIG,
                    uuid = registry_uuid)

    # Next configure a git backed StorageServer, serving the newly
    # created registry.
    config_dict = Dict{String, Any}()
    config_dict["host"] = "127.0.0.1"
    config_dict["port"] = 8080
    config_dict["local_registry"] = upstream_registry_url
    config_dict["cache_dir"] = joinpath(test_dir, "cache")
    config_dict["git_clones_dir"] = joinpath(test_dir, "data")
    config_dict["min_time_between_registry_updates"] = 0
    config_dict["gitconfig"] = TEST_GITCONFIG
    config = Config(config_dict)
    mkpath(config.cache_dir)

    # We won't actually run this server, but test its backend
    # functions, specifically through `fetch_test`.
    path = fetch_test(config, "/registries")
    @test isfile(path)
    registry_git = gitcmd(registry_dir, TEST_GITCONFIG)
    hash = readchomp(`$(registry_git) rev-parse --verify HEAD:`)
    initial_registry_resource = readchomp(path)
    @test initial_registry_resource == "/registry/$(registry_uuid)/$(hash)"
    path = fetch_test(config, initial_registry_resource)
    @test isfile(path)
    @test startswith(inflate_gzip(path), "Registry.toml")

    # Create a test package and register it.
    prepare_package(packages_dir, "FirstTest1.toml")
    first_test_dir = joinpath(packages_dir, "FirstTest")
    first_test_url = "file://$(first_test_dir)"
    register(first_test_dir, registry = registry_dir,
             repo = first_test_url,
             gitconfig = TEST_GITCONFIG, push = true)
    first_test_uuid = "d7508571-2240-4c50-b21c-240e414cc6d2"

    # This should now give a different hash for the registry.
    path = fetch_test(config, "/registries")
    @test isfile(path)
    @test readchomp(path) != initial_registry_resource
    path = fetch_test(config, readchomp(path))
    @test isfile(path)

    # Verify that the package resource is available.
    git = gitcmd(first_test_dir, TEST_GITCONFIG)
    hash = readchomp(`$git rev-parse --verify HEAD:`)
    path = fetch_test(config, "/package/$(first_test_uuid)/$(hash)")
    @test isfile(path)
    dir = joinpath(test_dir, "data", "packages", first_test_uuid)
    @test isdir(dir)
    git = gitcmd(dir, TEST_GITCONFIG)
    @test readchomp(`$git rev-parse --verify HEAD:`) == hash

    # Test the server metadata.
    meta = LocalPackageServer.collect_meta(config)
    @test meta["julia_version"] == string(VERSION)
    @test haskey(meta, "pkgserver_version")
    @test meta["packages_cached"] == 1
    @test meta["artifacts_cached"] == 0

    # Issue #3.
    # Create another test package and register it with a broken repo url.
    prepare_package(packages_dir, "Images1.toml")
    images_dir = joinpath(packages_dir, "Images")
    images_url = "file://$(images_dir)broken"
    register(images_dir, registry = registry_dir,
             repo = images_url,
             gitconfig = TEST_GITCONFIG, push = true)
    images_uuid = "916415d5-f1e6-5110-898d-aaa5f9f070e0"
    # Verify that the package resource is NOT available.
    git = gitcmd(images_dir, TEST_GITCONFIG)
    hash = readchomp(`$git rev-parse --verify HEAD:`)
    @test_throws ProcessFailedException fetch_test(config, "/package/$(images_uuid)/$(hash)")
    dir = joinpath(test_dir, "data", "packages", images_uuid)
    @test !isdir(dir)
    # Fix the URL and verify that the package resource IS available.
    prepare_package(packages_dir, "Images2.toml")
    images_url = "file://$(images_dir)"
    register(images_dir, registry = registry_dir,
             repo = images_url,
             gitconfig = TEST_GITCONFIG, push = true)
    git = gitcmd(images_dir, TEST_GITCONFIG)
    hash = readchomp(`$git rev-parse --verify HEAD:`)
    path = fetch_test(config, "/package/$(images_uuid)/$(hash)")
    @test isfile(path)
    dir = joinpath(test_dir, "data", "packages", images_uuid)
    @test isdir(dir)
    git = gitcmd(dir, TEST_GITCONFIG)
    @test readchomp(`$git rev-parse --verify HEAD:`) == hash
end

# Serve more than one local registry from the same server.
mktempdir(@__DIR__) do test_dir
    uuid1 = "11111111-1111-1111-1111-111111111111"
    uuid2 = "22222222-2222-2222-2222-222222222222"
    packages_dir = joinpath(test_dir, "packages")

    upstream1 = joinpath(test_dir, "upstream_registry1.git")
    upstream2 = joinpath(test_dir, "upstream_registry2.git")
    registry1 = joinpath(test_dir, "TestRegistry1")
    registry2 = joinpath(test_dir, "TestRegistry2")
    for (upstream, registry, uuid) in ((upstream1, registry1, uuid1),
                                       (upstream2, registry2, uuid2))
        mkpath(upstream)
        run(`git -C $(upstream) init --bare`)
        create_registry(registry, string("file://", upstream), push = true,
                        gitconfig = TEST_GITCONFIG, uuid = uuid)
    end

    # One package in each registry
    prepare_package(packages_dir, "FirstTest1.toml")
    first_test_dir = joinpath(packages_dir, "FirstTest")
    first_test_url = "file://$(first_test_dir)"
    register(first_test_dir, registry = registry1,
             repo = first_test_url,
             gitconfig = TEST_GITCONFIG, push = true)
    first_test_uuid = "d7508571-2240-4c50-b21c-240e414cc6d2"
    prepare_package(packages_dir, "Images1.toml")
    images_dir = joinpath(packages_dir, "Images")
    images_url = "file://$(images_dir)"
    register(images_dir, registry = registry2,
             repo = images_url,
             gitconfig = TEST_GITCONFIG, push = true)
    images_uuid = "916415d5-f1e6-5110-898d-aaa5f9f070e0"

    config_dict = Dict{String, Any}()
    config_dict["host"] = "127.0.0.1"
    config_dict["port"] = 8080
    config_dict["local_registries"] = Dict(uuid1 => string("file://", upstream1),
                                           uuid2 => string("file://", upstream2))
    config_dict["cache_dir"] = joinpath(test_dir, "cache")
    config_dict["git_clones_dir"] = joinpath(test_dir, "data")
    config_dict["min_time_between_registry_updates"] = 0
    config_dict["gitconfig"] = TEST_GITCONFIG
    config = Config(config_dict)
    mkpath(config.cache_dir)

    # Both registries are advertised, and each has a clone directory of
    # its own, named after its UUID.
    registry_hash(dir) =
        readchomp(`$(gitcmd(dir, TEST_GITCONFIG)) rev-parse --verify HEAD:`)
    hash1 = registry_hash(registry1)
    hash2 = registry_hash(registry2)
    registries = readlines(fetch_test(config, "/registries"))
    @test "/registry/$(uuid1)/$(hash1)" in registries
    @test "/registry/$(uuid2)/$(hash2)" in registries
    @test isdir(joinpath(test_dir, "data", "registries", uuid1))
    @test isdir(joinpath(test_dir, "data", "registries", uuid2))
    @test !isdir(joinpath(test_dir, "data", "registry"))

    # Both registries can be downloaded, and each request is answered
    # with the registry it asked for.
    @test occursin("uuid = \"$(uuid1)\"", inflate_gzip(fetch_test(config, "/registry/$(uuid1)/$(hash1)")))
    @test occursin("uuid = \"$(uuid2)\"", inflate_gzip(fetch_test(config, "/registry/$(uuid2)/$(hash2)")))

    # A package from each registry. The second is only found after the
    # first storage server declines it.
    first_test_hash = registry_hash(first_test_dir)
    images_hash = registry_hash(images_dir)
    @test isfile(fetch_test(config, "/package/$(first_test_uuid)/$(first_test_hash)"))
    @test isfile(fetch_test(config, "/package/$(images_uuid)/$(images_hash)"))

    # Configuring a registry with the wrong UUID is an error.
    config_dict["local_registries"] = Dict(uuid1 => string("file://", upstream2))
    config_dict["git_clones_dir"] = joinpath(test_dir, "data_mismatch")
    @test_throws ErrorException update_registries(Config(config_dict))
end
