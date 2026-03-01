# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY cosign.pub /

# Base Image
FROM quay.io/fedora/fedora-kinoite:43

## Other possible base images:
# FROM quay.io/fedora/fedora-kinoite:latest  # Always latest stable Kinoite
# FROM quay.io/fedora/fedora-silverblue:43   # GNOME variant
# FROM quay.io/fedora/fedora-bootc:43        # Minimal Fedora bootc (no desktop)

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### CHROME FIXES
## 1. PWA FIX: Hardcode CHROME_WRAPPER so Chrome doesn't use readlink -f, which
##    follows /opt -> /usr/lib/opt at deploy time and writes the wrong path into
##    PWA .desktop Exec= lines causing KDE to fail launching them.
## 2. TOUCHPAD NAVIGATION: Inject flag via set -- so it applies to every Chrome
##    invocation (main browser and all PWAs) regardless of which is opened first.
RUN sed -i \
    -e 's|CHROME_WRAPPER="`readlink -f "$0"`"|CHROME_WRAPPER="/opt/google/chrome/google-chrome"|' \
    -e '/^HERE=/a set -- --enable-features=TouchpadOverscrollHistoryNavigation "$@"' \
    /opt/google/chrome/google-chrome

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
