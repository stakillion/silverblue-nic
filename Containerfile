ARG FEDORA_VER=44

# ==============================================================================
# Stage 1: Build rootfs with all packages, kernel modules, and configuration
# ==============================================================================
FROM quay.io/fedora/fedora-silverblue:${FEDORA_VER} AS rootfs

# Enable RPM Fusion (Free & Non-Free)
RUN dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Enable COPR Repositories
RUN dnf copr enable -y bazzite-org/obs-vkcapture && \
    dnf copr enable -y yannmasoch/nautilus-my-computer && \
    dnf copr enable -y aneagle/gnome-rounded-blur

# Add Brave's official repository
RUN curl -fsSLo /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

# Add Tailscale's official repository
RUN curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# Ensure /var/opt exists
RUN mkdir -p /var/opt

# Add/remove system packages
RUN rm -f /etc/dnf/protected.d/grub* /etc/dnf/protected.d/shim* && \
    dnf remove -y \
        rpm-ostree rpm-ostree-libs gnome-software-rpm-ostree \
        shim-* grub2-* bootupd \
        firefox firefox-langpacks \
        toolbox && \
    dnf install -y --setopt=tsflags=noscripts \
        systemd-boot-unsigned \
        libratbag-ratbagd steam-devices obs-vkcapture \
        dnscrypt-proxy tailscale \
        brave-origin waydroid distrobox \
        nautilus-my-computer gnome-tweaks gnome-rounded-blur \
        neovim htop hyfetch yt-dlp && \
    dnf swap -y ffmpeg-free ffmpeg --allowerasing

# Recompile glib schemas skipped by tsflags=noscripts
RUN glib-compile-schemas /usr/share/glib-2.0/schemas/

# Symlink Brave icons
RUN for res in 16 24 32 48 64 128 256; do \
        mkdir -p /usr/share/icons/hicolor/${res}x${res}/apps && \
        ln -sf /opt/brave.com/brave-origin/product_logo_${res}.png /usr/share/icons/hicolor/${res}x${res}/apps/brave-origin.png; \
    done

# Copy custom system configurations and local binaries into the image
COPY rootfs/usr/ /usr/
COPY rootfs/etc/ /etc/

# Configure dnscrypt
RUN sed -i -E "s/^#[[:space:]]*server_names[[:space:]]*=.*/server_names = ['quad9-dnscrypt-ip4-filter-pri']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^[[:space:]]*require_nofilter[[:space:]]*=.*/require_nofilter = false/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^#[[:space:]]*forwarding_rules[[:space:]]*=.*/forwarding_rules = '\/etc\/dnscrypt-proxy\/forwarding-rules.txt'/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

# Configure altfiles in nsswitch.conf
RUN sed -i 's/^passwd:.*/passwd:     files altfiles/' /etc/nsswitch.conf && \
    sed -i 's/^group:.*/group:      files altfiles/' /etc/nsswitch.conf

# Enable services
RUN systemctl enable dnscrypt-proxy.service tailscaled.service

# Generate initramfs
RUN KVER=$(ls /usr/lib/modules | head -n 1) && \
    mkdir -p /var/roothome && \
    env DRACUT_NO_XATTR=1 dracut --force --kver "${KVER}" "/usr/lib/modules/${KVER}/initramfs.img"

# Clean up
RUN dnf clean all && \
    rm -rf /var/lib/libvirt/* /var/lib/dnf/* /var/lib/iscsi /run/akmods /run/dnf /tmp/* /var/tmp/* /var/cache/* /var/log/*

# Lint complete rootfs before splitting kernel or chunking
RUN bootc container lint

# ==============================================================================
# Stage 2: Split raw kernel/initramfs out of rootfs using bootc
# ==============================================================================
FROM rootfs AS split
RUN mkdir -p /kernel && \
    bootc container split-kernel-and-rootfs \
      --rootfs / \
      --output /kernel

# ==============================================================================
# Stage 3: Rechunk stripped base OS via chunkah
# ==============================================================================
FROM quay.io/coreos/chunkah AS chunkah
RUN --mount=from=split,src=/,target=/chunkah,ro \
    chunkah build \
        --max-layers 256 \
        --prune /ostree \
        --prune /sysroot/ostree \
        --prune /kernel \
        --output oci:/run/src/out

# ==============================================================================
# Stage 4: Load chunked base image
# ==============================================================================
FROM oci:out AS rootfs-chunked
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ==============================================================================
# Stage 5: Build UKI using extracted kernel directory from Stage 2
# ==============================================================================
FROM quay.io/fedora/fedora-bootc:latest AS sealed-uki
RUN dnf install -y systemd-ukify sbsigntools && dnf clean all

RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=secret,id=mok_key \
    --mount=type=secret,id=mok_crt \
    --mount=type=bind,from=rootfs-chunked,target=/run/target,ro \
    --mount=type=bind,from=split,src=/kernel,target=/kernel,ro \
    set -euo pipefail && \
    KVER=$(ls /kernel) && \
    mkdir -p /out && \
    bootc container ukify \
      --rootfs /run/target \
      --kernel-dir "/kernel/${KVER}" \
      -- \
      --output "/out/${KVER}.efi" \
      --signtool sbsign \
      --secureboot-private-key /run/secrets/mok_key \
      --secureboot-certificate /run/secrets/mok_crt

# ==============================================================================
# Stage 6: Final Image (Chunked Base + UKI top layer)
# ==============================================================================
FROM rootfs-chunked AS final
COPY --from=sealed-uki /out/*.efi /boot/EFI/Linux/
