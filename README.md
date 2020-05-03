# LocalPackageServer

Implementation of a Julia Storage Server for a single registry, where
the registry and the registered packages are dynamically retrieved
from their git repositories. For creation of a registry, see the
companion package
[LocalRegistry](https://github.com/GunnarFarneback/LocalRegistry.jl).

This package is a simplified fork of the
[PkgServer](https://github.com/JuliaPackaging/PkgServer.jl) package,
to which the dynamic storage server has been added. It can also be
configured as a low-feature Julia Package Server with a built in
storage server.

For terminology and background, see
https://github.com/JuliaLang/Pkg.jl/issues/1377.

## Usage

```bash
# Enter package directory
$ cd LocalPackageServer
# Launch server to run in foreground
$ julia --project bin/run_server.jl CONFIG_FILE
```
where `CONFIG_FILE` is a configuration file in TOML format. The
content is explained below.

## Package Server Configuration

An example configuration file for running as a package server with
a builtin storage server:
```
host = "localhost"
port = "8000"
local_registry = REGISTRY_URL
pkg_server = "https://pkg.julialang.org"
cache_dir = "/tmp/cache"
git_clones_dir = "/tmp/data"
min_time_between_registry_updates = 60
```
Replace `REGISTRY_URL` with the URL to your local registry (the same
that you would use in a `registry add` command). If you want to use
the package server from other computers you need to replace
`localhost` with a public address.

### Using the Package Server

Start a 1.4 or newer version of Julia, referring all Pkg operations to
this package server:
```
$ JULIA_PKG_SERVER=http://localhost:8000 julia
```

In order to add your registry through the package server, you need to do
```
using Pkg
pkg"registry add UUID"
```
where `UUID` is the UUID of your local registry.

When https://github.com/JuliaLang/Pkg.jl/pull/1804 has been merged and
included in Julia (hopefully for Julia 1.5), you don't need to specify
the UUID,
```
using Pkg
pkg"registry add"
```
without arguments suffices. For new Julia installations (when no
registry has been previously added) it will be added automatically.

## Storage Server Configuration

The major difference to configuration as a Package Server is that
`pkg_server` is omitted.
```
host = "localhost"
port = "8080"
local_registry = REGISTRY_URL
cache_dir = "/tmp/cache"
git_clones_dir = "/tmp/data"
min_time_between_registry_updates = 60
```

Then you configure this as a storage server for
[PkgServer](https://github.com/JuliaPackaging/PkgServer.jl). Adding
your local registry is done as above after you have pointed
"JULIA_PKG_SERVER" to your PkgServer instance.

## Configuration Variables
* `host`: The host name the server will listen to.
* `port`: The port number the server will listen to.
* `local_registry`: URL from which your local registry can be cloned.
* `pkg_server`: The package server to forward requests for non-local
  packages to.
* `cache_dir`: A directory where package and registry revisions will
  be stored. This cache is used for both local and non-local
  packages and registries.
* `git_clones_dir`: A directory where clones of your local registry
  and local packages will be stored.
* `min_time_between_registry_updates`: Minimum time in seconds before
  checking registries for updates. Updates are only triggered when
  either a package or a repository is requested.
* `gitconfig`: Extra configuration for git when cloning or pulling
  local registries and packages. This is specified as a key/value
  mapping, e.g.
```
[gitconfig]
"user.name" = "Jane Doe"
"user.email" = "unknown@example.com"
```
