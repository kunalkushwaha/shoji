# shoji on Linux: a headless WebKit browser for agents (WPE WebKit 2.54+, no Chrome).
#
#   docker build -t shoji .
#   docker run -d --name shoji shoji                       # a headless browser, idle-exits after 30 min
#   docker exec shoji shoji ctl open https://example.com
#   docker exec shoji shoji ctl snapshot
#
# Or one-off: docker run --rm shoji ctl open https://example.com (starts its own browser).

# ---- build: Swift 6.3 (swift.org's Debian 12 build) + WPE headers on Debian testing ----
FROM debian:testing AS build
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libwpewebkit-2.0-dev libpng-dev build-essential pkg-config ca-certificates curl \
      binutils git libc6-dev libcurl4-openssl-dev libedit2 libncurses-dev libpython3-dev libsqlite3-0 \
      libxml2-dev libz3-dev tzdata unzip zlib1g-dev gnupg \
    && rm -rf /var/lib/apt/lists/*
# swift-build links libxml2.so.2; testing ships libxml2.so.16 under another package name
RUN echo "deb http://deb.debian.org/debian bookworm main" > /etc/apt/sources.list.d/bookworm.list \
    && printf 'Package: *\nPin: release n=bookworm\nPin-Priority: 100\n' > /etc/apt/preferences.d/bookworm \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm libxml2 \
    && rm -rf /var/lib/apt/lists/*
ARG SWIFT=6.3
RUN curl -fsSL https://download.swift.org/swift-${SWIFT}-release/debian12/swift-${SWIFT}-RELEASE/swift-${SWIFT}-RELEASE-debian12.tar.gz \
      | tar -xz --strip-components=2 -C /usr
WORKDIR /src
COPY Package.swift ./
COPY Sources Sources
RUN swift build -c release --static-swift-stdlib && strip .build/release/shoji

# ---- runtime: WPE WebKit and what it needs at run time, nothing else ----
FROM debian:testing
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libwpewebkit-2.0-1 libgles2 libpng16-16t64 shared-mime-info fonts-dejavu-core ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Pages in Chinese, Japanese or Korean: docker build --build-arg CJK=1 (adds ~100 MB of fonts)
ARG CJK=0
RUN if [ "$CJK" = 1 ]; then apt-get update && apt-get install -y --no-install-recommends fonts-noto-cjk \
      && rm -rf /var/lib/apt/lists/*; fi
# WebKit's own sandbox (bubblewrap) can't create namespaces in an unprivileged container;
# the container is the sandbox here, as with Chromium's --no-sandbox in Playwright's images.
ENV WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
COPY --from=build /src/.build/release/shoji /usr/local/bin/shoji
RUN useradd --create-home shoji
USER shoji
WORKDIR /home/shoji
ENTRYPOINT ["shoji"]
CMD ["--headless"]
