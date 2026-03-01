# Build base with arch-bootstrap
FROM cgr.dev/chainguard/wolfi-base:latest AS rootfs

ENV VERSION="2026.02.01"
ENV SHASUM="5debe75527010999719815ca964b6f630eac525167c6ad00ba1f7aa510ba657a"
ENV DRACTUT_NO_XATTR=1

RUN apk add gnutar zstd curl && \
    curl -fLOJ --retry 3 https://fastly.mirror.pkgbuild.com/iso/$VERSION/archlinux-bootstrap-x86_64.tar.zst && \
    echo "$SHASUM archlinux-bootstrap-x86_64.tar.zst" > sha256sum.txt && \
    sha256sum -c sha256sum.txt || exit 1 && \
    tar -xf /archlinux-bootstrap-x86_64.tar.zst --numeric-owner && \
    rm -f /archlinux-bootstrap-x86_64.tar.zst && \
    apk del gnutar zstd curl && \
    apk cache clean

FROM scratch AS system
COPY --from=rootfs /root.x86_64/ /

# Copy homebrew and put it in its own layer
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /
RUN setfattr -n user.component -v "homebrew" "/usr/share/homebrew.tar.zst"

# Set it up such that pacman is always cleaned after installs
RUN echo -e "[Trigger]\n\
Operation = Install\n\
Operation = Upgrade\n\
Type = Package\n\
Target = *\n\
\n\
[Action]\n\
Description = Cleaning up package cache...\n\
Depends = coreutils\n\
When = PostTransaction\n\
Exec = /usr/bin/rm -rf /var/cache/pacman/pkg" > /usr/share/libalpm/hooks/package-cleanup.hook

# replacing with cachyos' pacman config and mirrorlists
RUN sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist
RUN rm -f /etc/pacman.conf && \
    curl --retry 3 https://raw.githubusercontent.com/CachyOS/docker/refs/heads/master/pacman.conf -o /etc/pacman.conf && \
    curl --retry 3 https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist -o /etc/pacman.d/cachyos-mirrorlist

RUN touch /var/log/pacman.log
# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# assign user.component to every package
# script by hec
RUN mkdir -p /usr/libexec
COPY files/usr/libexec /usr/libexec
COPY files/usr/share /usr/share

# populate arch linux keyring first
RUN pacman-key --init && \
    pacman-key --populate

# transitioning to cachyos >:D
RUN pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key F3B607488DB35A47 && \
    pacman -Sy && \
    pacman -S --needed --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist cachyos-hooks chwd && \
    pacman -Syu --noconfirm

# Chaotic AUR repo
RUN pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
RUN pacman-key --init && pacman-key --lsign-key 3056513887B78AEB
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' --noconfirm
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' --noconfirm
RUN echo -e '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf

# add a repo for bootc by hec
RUN pacman-key --recv-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB && \
    echo -e '[bootc]\nSigLevel = Required\nServer=https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo' >> /etc/pacman.conf

# dracut errors out on missing i18n_vars
# https://github.com/dracutdevs/dracut/issues/868
RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    echo 'i18n_vars="/usr/share/kbd/consolefonts  /usr/share/kbd/keymaps"' >> /usr/lib/dracut/dracut.conf.d/lumaeris-cachyos-deckify.conf

RUN pacman -Syu --noconfirm

RUN pacman -S --needed --noconfirm \
  bootc/uupd && \
  systemctl enable uupd.timer

# replace system updater for gaming mode
COPY files/usr/bin /usr/bin

# Allow people in group wheel to run all commands
RUN mkdir -p /etc/sudoers.d && \
    echo "%wheel ALL=(ALL) ALL" | \
    tee "/etc/sudoers.d/wheel"

# Add greetd user manually for rebase issues that arise
RUN useradd -M -G video,input -s /usr/bin/nologin greeter || true

# Symlink Vi to Vim / Make it to where a user can use vi in terminal command to use vim automatically | Thanks Tulip
RUN ln -s ./vim /usr/bin/vi

# enable some necessary services
RUN systemctl enable NetworkManager.service && \
    systemctl enable brew-setup.service &&\
    systemctl --global enable cachyos-gamescope-autologin.service

# https://github.com/bootc-dev/bootc/issues/1801
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img"

# Necessary for general behavior expected by image-based systems
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /mnt /opt /boot /home /root /usr/local /srv /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var /run /tmp && \
    ln -s sysroot/ostree /ostree && ln -s var/roothome /root && ln -s var/srv /srv && ln -s var/opt /opt && ln -s var/mnt /mnt && ln -s var/home /home && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

# remove leftover file created by cachyos' vapor theme package
RUN rm -f /README.md

# Link /etc/os-release to its equivalent in /usr/lib/os-release
RUN ln -sf ../usr/lib/os-release /etc/os-release

RUN ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

RUN mkdir -p /etc/pki/containers
COPY files/etc /etc
COPY cosign.pub /etc/pki/containers/ganee0.pub

# Setup a temporary root passwd (changeme) for dev purposes
# RUN pacman -S whois --noconfirm && pacman -S --clean --noconfirm
# RUN usermod -p "$(echo "changeme" | mkpasswd -s)" root

# Automount ext4/btrfs drives, feel free to mount your own in fstab if you understand how to do so
# To turn off, run sudo ln -s /dev/null /etc/media-automount.d/_all.conf
RUN git clone --depth=1 https://github.com/Zeglius/media-automount-generator /tmp/media-automount-generator && \
    cd /tmp/media-automount-generator && \
    ./install.sh && \
    rm -rf /tmp/media-automount-generator

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
