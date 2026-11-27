# Builds shoji's Arch package (makepkg) against Arch's own wpewebkit and glibc.
# Used by scripts/dist-linux.sh; Swift comes from swift.org (Arch has no official package;
# on a real Arch machine, AUR's swift-bin or swift-language does the same).
FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed base-devel git wpewebkit libpng zlib pkgconf \
      libxml2-legacy ncurses libedit sqlite curl python \
    && pacman -Scc --noconfirm
ARG SWIFT=6.3
RUN curl -fsSL https://download.swift.org/swift-${SWIFT}-release/debian12/swift-${SWIFT}-RELEASE/swift-${SWIFT}-RELEASE-debian12.tar.gz \
      | tar -xz --strip-components=2 -C /usr \
    && ln -sf libncursesw.so.6 /usr/lib/libncurses.so.6   # swift.org's build asks for the non-wide name
# makepkg refuses to run as root
RUN useradd -m builder
USER builder
WORKDIR /pkg
# --skipchecksums: the local source tarball is a git archive, not GitHub's (whose sum the PKGBUILD has)
CMD ["makepkg", "--nodeps", "--force", "--noconfirm", "--skipchecksums"]
