FROM julia:latest

# Install git
RUN apt-get update \
        && apt-get -y install git \
        && rm -rf /var/cache/apt


# Create unprivileged user
ENV APPDIR="/app/"
RUN useradd -d $APPDIR pkgserver \
        && mkdir $APPDIR $APPDIR/storage \
        && chown -R pkgserver:pkgserver $APPDIR
USER pkgserver
WORKDIR $APPDIR


# Setup git
RUN git config --global credential.helper \
        '!f() { echo "username=${GIT_USER}\npassword=${GIT_PASSWORD}"; }; f'


# Install LocalPackageServer
ADD --chown=pkgserver:pkgserver *.toml $APPDIR/LocalPackageServer/
ADD --chown=pkgserver:pkgserver src    $APPDIR/LocalPackageServer/src/
RUN julia --project=LocalPackageServer \
        -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'


# Run server
ADD --chown=pkgserver:pkgserver deploy/run_server.jl .
CMD ["julia", "--project=LocalPackageServer", "run_server.jl"]
