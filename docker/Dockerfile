# Farming Simulator 25 dedicated server (wine) for Pelican/Wings.
# Self-contained: Arch Linux + wine-staging + TigerVNC/noVNC + XFCE, no third-party server image.
# Packages come from a dated Arch Linux Archive snapshot, so a rebuild gives the same versions.
ARG ARCH_IMAGE=archlinux:base-20251019.0.436919
ARG ARCH_SNAPSHOT=2025/11/13

# save-on-stop helper mod (FS25_PelicanSave.zip)
FROM python:3.12-alpine AS mod
COPY mod/ /src/
RUN cd /src && python3 make-icon.py icon_pelicanSave.dds && python3 pack.py /FS25_PelicanSave.zip

# noVNC + websockify are not in the Arch repos: official release tarballs, checksums pinned
FROM alpine:3.20 AS novnc
ARG NOVNC_VERSION=1.6.0
ARG NOVNC_SHA256=5066103959ef4e9b10f37e5a148627360dd8414e4cf8a7db92bdbd022e728aaa
ARG WEBSOCKIFY_VERSION=0.13.0
ARG WEBSOCKIFY_SHA256=b6413e364efd04f3c92ec8c17747e3c4adc20157c2ef1c5d019a26d944a46df8
RUN set -eux; \
    apk add --no-cache curl; \
    curl -fsSL -o /novnc.tgz "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz"; \
    echo "${NOVNC_SHA256}  /novnc.tgz" | sha256sum -c -; \
    curl -fsSL -o /ws.tgz "https://github.com/novnc/websockify/archive/refs/tags/v${WEBSOCKIFY_VERSION}.tar.gz"; \
    echo "${WEBSOCKIFY_SHA256}  /ws.tgz" | sha256sum -c -; \
    mkdir -p /out/novnc /out/websockify; \
    tar -xzf /novnc.tgz -C /out/novnc --strip-components=1; \
    tar -xzf /ws.tgz -C /out/websockify --strip-components=1; \
    rm -rf /out/novnc/tests /out/novnc/docs /out/websockify/tests

FROM ${ARCH_IMAGE}
ARG ARCH_SNAPSHOT
# wine 10.1: the version this setup is tested with (newer builds have broken the FS25 server before,
# https://bugs.winehq.org/show_bug.cgi?id=56790)
ARG WINE_PKG=https://archive.archlinux.org/packages/w/wine-staging/wine-staging-10.1-1-x86_64.pkg.tar.zst
ARG WINE_SHA256=3ad213aefa8483ff0ccb0d8fb8b7f366507b0c60c1b91c485324d72c48abcce0

RUN set -eux; \
    echo "Server = https://archive.archlinux.org/repos/${ARCH_SNAPSHOT}/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist; \
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf; \
    sed -i 's/^#\?NoExtract.*/NoExtract = usr\/share\/help\/* usr\/share\/doc\/* usr\/share\/gtk-doc\/* usr\/share\/man\/* usr\/share\/info\/*/' /etc/pacman.conf; \
    # signatures are still verified against the Arch keyring; TrustAll skips the web-of-trust level,
    # whose signatures on some packager keys have expired since the snapshot date
    sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional TrustAll/' /etc/pacman.conf; \
    pacman-key --init; pacman-key --populate archlinux; \
    pacman -Sy --noconfirm archlinux-keyring; \
    pacman -Su --noconfirm; \
    pacman -S --noconfirm --needed \
      catatonit bash coreutils diffutils findutils gawk grep sed procps-ng iproute2 which \
      curl ca-certificates socat nodejs python \
      tigervnc xorg-xkbcomp xkeyboard-config xorg-fonts-misc ttf-dejavu ttf-liberation \
      dbus xfce4-session xfwm4 xfdesktop xfce4-panel xfce4-settings xfce4-terminal thunar adwaita-icon-theme \
      gnutls lib32-gnutls; \
    curl -fsSL -o /tmp/wine.pkg.tar.zst "${WINE_PKG}"; \
    echo "${WINE_SHA256}  /tmp/wine.pkg.tar.zst" | sha256sum -c -; \
    pacman -U --noconfirm /tmp/wine.pkg.tar.zst; \
    wine --version; \
    rm -rf /tmp/* /var/cache/pacman/pkg/* /var/lib/pacman/sync/* /etc/pacman.d/gnupg

COPY --from=novnc /out/novnc /usr/share/novnc
COPY --from=novnc /out/websockify /usr/share/websockify
COPY --from=mod /FS25_PelicanSave.zip /usr/local/share/fs25-pelican/FS25_PelicanSave.zip
COPY templates/ /usr/local/share/fs25-pelican/templates/
COPY entrypoint.sh /entrypoint.sh
COPY fs25-pelican.sh /usr/local/bin/fs25-pelican
COPY fs25-webadmin.mjs /usr/local/bin/fs25-webadmin.mjs

RUN set -eux; \
    printf '#!/bin/sh\ncd /usr/share/websockify && exec python3 -m websockify "$@"\n' >/usr/local/bin/websockify; \
    chmod 755 /entrypoint.sh /usr/local/bin/fs25-pelican /usr/local/bin/websockify; \
    chmod 644 /usr/local/bin/fs25-webadmin.mjs; \
    # Wings runs the container as the node's uid/gid (any number) with a read-only root filesystem:
    # /etc/passwd and /etc/group point into /tmp (tmpfs), the entrypoint adds the running uid there
    cp /etc/passwd /etc/passwd.image; cp /etc/group /etc/group.image; \
    ln -sf /tmp/passwd /etc/passwd; ln -sf /tmp/group /etc/group; \
    # X server writes compiled keymaps here
    rm -rf /var/lib/xkb; ln -s /tmp/xkb /var/lib/xkb; \
    # older volumes have wine symlinks to /opt/fs25
    mkdir -p /home/container; chmod 777 /home/container; ln -s /home/container /opt/fs25

# USER=nobody: wine names the profile dir after $USER (drive_c/users/nobody)
ENV HOME=/home/container \
    USER=nobody \
    TMPDIR=/home/container/tmp \
    TERM=xterm \
    LANG=C.UTF-8

WORKDIR /home/container
USER 988:988

LABEL org.opencontainers.image.title="pelican-fs25" \
      org.opencontainers.image.description="Farming Simulator 25 dedicated server (wine) for Pelican" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/usr/bin/catatonit", "--"]
CMD ["/entrypoint.sh"]
