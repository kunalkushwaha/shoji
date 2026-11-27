#!/bin/sh
# Build the Linux binary in Docker and pack it: dist/shoji-<version>-linux-<arch>.tar.gz
# The binary carries Swift's runtime (--static-swift-stdlib); it needs WPE WebKit 2.54+
# from the system: Debian testing/sid (libwpewebkit-2.0-1 libgles2 shared-mime-info) or Arch (wpewebkit).
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^let version = "\(.*\)"/\1/p' Sources/shoji/main.swift)
arch=$(uname -m)
docker build --target build -t shoji-build .
dir="dist/shoji-$version-linux-$arch"
rm -rf "$dir" && mkdir -p "$dir"
id=$(docker create shoji-build)
docker cp "$id:/src/.build/release/shoji" "$dir/shoji"
docker rm "$id" >/dev/null
cp README.md "$dir/"
tar -czf "$dir.tar.gz" -C dist "$(basename "$dir")"
echo "$dir.tar.gz ($(du -h "$dir.tar.gz" | cut -f1))"
