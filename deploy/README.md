# Deployment of LocalPackageServer

Deploying a `LocalPackageServer` instance in a docker environment should be as
easy as filling out a `.env` file and running `make`.

Here is a detailed, step-by-step deployment procedure:

1. Clone this package and `cd` to the `deploy` directory:

   ```
   git clone https://github.com/GunnarFarneback/LocalPackageServer.jl.git
   cd LocalPackageServer.jl/deploy
   ```

1. Fill out a `.env` file. You can start with the template provided in
   `.env.example` and adapt it to your needs:
   
   ```
   cp .env.example .env
   $EDITOR .env
   ```
   
   The `LocalPackageServer` behavior can be customized using the following
   environment variables:
   
   - `SERVER_PORT`: port where `LocalPackageServer` will be
     reachable. Mandatory, default value: `8000`.
     
   - `JULIA_LOCAL_REGISTRY`: URL of the local registry to be served. If this
     variable is not set, `LocalPackageServer` will be configured as a storage
     server only). Optional, unset by default.
     
   - `GIT_USER` and `GIT_PASSWORD`: git credentials to be used to access the
     local registry. Optional, unset by default.
     
   - `JULIA_PKG_SERVER`: package server which will serve requests for non-local
     packages. Optional, default value: `https://pkg.julialang.org`.
 
   - `MIN_TIME_BETWEEN_REGISTRY_UPDATES`: minimum time (in seconds) before
     checking registries for updates. Optional, default value: `60`.
     
1. Start the server using `make`:

   ```
   make up
   ```
   
   The following `make` verbs are supported:
   
   - `up`: start the server container in the background (after having built the
     Docker image if necessary).
     
   - `logs`: display the server logs (you'll have to kill this with
     <kbd>Ctrl+c</kbd> when you're done).
     
   - `down`: stop the server container.
   
   - `destroy`: stop the server container and remove the persistent volumes
     attached to it.


