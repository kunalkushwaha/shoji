#!/bin/sh
# Linux packages of shoji, all built in Docker, into dist/:
#
#   scripts/dist-linux.sh [tar] [deb] [arch]      (default: all three)
#
#   tar   shoji-<ver>-linux-<arch>.tar.gz   the binary + README (Debian testing/sid)
#   deb   shoji_<ver>-1_<debarch>.deb        sudo apt install ./shoji_*.deb (Debian testing/sid)
#   arch  shoji-<ver>-1-<arch>.pkg.tar.zst  sudo pacman -U shoji-*.pkg.tar.zst (Arch)
#
# shoji needs WPE WebKit 2.54+ (WPEPlatform). Only Debian testing/sid and Arch ship it;
# everywhere else (Ubuntu, Fedora, Debian 13) use the Docker image. The binaries carry
# Swift's runtime (--static-swift-stdlib) and use the system's WPE WebKit and glibc, so
# each distro gets its own build: the Debian one needs glibc 2.43+.
# Packages are for this machine's architecture (x86_64 or aarch64: run it there).
set -eu
cd "$(dirname "$0")/.."
version=$(sed -n 's/^let version = "\(.*\)"/\1/p' Sources/shoji/main.swift)
arch=$(uname -m)
case "$arch" in x86_64) debarch=amd64 ;; aarch64) debarch=arm64 ;; *) echo "unsupported: $arch" >&2; exit 1 ;; esac
targets=${*:-tar deb arch}
mkdir -p dist

want() { case " $targets " in *" $1 "*) return 0 ;; esac; return 1; }

bin=dist/.debian-shoji
trap 'rm -f "$bin"' EXIT
debian_binary() {
  [ -f "$bin" ] && return
  docker build --target build -t shoji-build .
  id=$(docker create shoji-build)
  docker cp "$id:/src/.build/release/shoji" "$bin"
  docker rm "$id" >/dev/null
}

if want tar; then
  debian_binary
  dir="dist/shoji-$version-linux-$arch"
  rm -rf "$dir" && mkdir -p "$dir"
  cp "$bin" "$dir/shoji"
  cp README.md "$dir/"
  tar -czf "$dir.tar.gz" -C dist "$(basename "$dir")"
  rm -rf "$dir"
  echo "built $dir.tar.gz ($(du -h "$dir.tar.gz" | cut -f1))"
fi

if want deb; then
  debian_binary
  # the newest glibc symbol version the binary uses: its libc6 floor
  glibc=$(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)
  root=$(mktemp -d) && chmod 755 "$root"
  install -Dm755 "$bin" "$root/usr/bin/shoji"
  install -Dm644 README.md "$root/usr/share/doc/shoji/README.md"
  install -Dm644 docs/linux.md "$root/usr/share/doc/shoji/linux.md"
  mkdir -p "$root/DEBIAN"
  sed -e "s/@VERSION@/$version-1/" -e "s/@ARCH@/$debarch/" -e "s/@GLIBC@/$glibc/" \
      -e "s/@SIZE@/$(du -sk "$root/usr" | cut -f1)/" packaging/debian/control.in > "$root/DEBIAN/control"
  deb="dist/shoji_${version}-1_${debarch}.deb"
  dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
  rm -rf "$root"
  echo "built $deb ($(du -h "$deb" | cut -f1); needs libc6 >= $glibc)"
fi

if want arch; then
  docker build -t shoji-arch-build packaging/arch
  work=$(mktemp -d)
  chmod 777 "$work"
  cp packaging/arch/PKGBUILD "$work/"
  # the source as GitHub would serve it for the tag (uncommitted changes included), so
  # makepkg finds it here instead of downloading it
  rev=$(git stash create || true)
  git archive --format=tar.gz --prefix="shoji-$version/" -o "$work/shoji-$version.tar.gz" "${rev:-HEAD}"
  docker run --rm -v "$work":/pkg shoji-arch-build
  for f in "$work"/shoji-*.pkg.tar.zst; do
    cp "$f" dist/ && echo "built dist/$(basename "$f") ($(du -h "$f" | cut -f1))"
  done
  docker run --rm -v "$work":/pkg --user root shoji-arch-build rm -rf /pkg/src /pkg/pkg
  rm -rf "$work"
fi
