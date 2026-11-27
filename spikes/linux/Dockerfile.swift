# Dev image for the Linux port: WPE WebKit 2.54 + the Swift toolchain (swift.org's Debian 12 build).
FROM shoji-linux-dev
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      binutils git libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev libpython3-dev libsqlite3-0 \
      libxml2-dev libz3-dev tzdata unzip zlib1g-dev gnupg \
    && rm -rf /var/lib/apt/lists/*
# swift-build (Debian 12 build) links libxml2.so.2; testing ships libxml2.so.16 under another
# package name, so bookworm's libxml2 installs alongside it.
RUN echo "deb http://deb.debian.org/debian bookworm main" > /etc/apt/sources.list.d/bookworm.list \
    && printf 'Package: *\nPin: release n=bookworm\nPin-Priority: 100\n' > /etc/apt/preferences.d/bookworm \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm libxml2 \
    && rm -rf /var/lib/apt/lists/*
ARG SWIFT=6.3
RUN curl -fsSL https://download.swift.org/swift-${SWIFT}-release/debian12/swift-${SWIFT}-RELEASE/swift-${SWIFT}-RELEASE-debian12.tar.gz \
      | tar -xz --strip-components=2 -C /usr \
    && swift --version
