using LocalPackageServer, LocalRegistry, Pkg, Test, Inflate
using LocalPackageServer: fetch_resource, cache_path, tempfilename
using LocalPackageServer: update_registries, ContentState
using LocalPackageServer: GitStorageServer, Config

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
