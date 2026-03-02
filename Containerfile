# Base container for building the image.
FROM cgr.dev/chainguard/wolfi-base:latest AS rootfs

# Environment variables to export to the image.
ENV VERSION="2026.03.01"
ENV SHASUM="eb52fd74f466658f039f2f7fe9bced015d29b23c569e72c5abb7015bdb6d5c7f"
ENV DRACUT_NO_XATTR=1

# Needed container pkgs for downloading and extracting the bootstrap.
RUN apk add gnutar zstd curl && \
    curl -fLOJ --retry 3 https://fastly.mirror.pkgbuild.com/iso/$VERSION/archlinux-bootstrap-x86_64.tar.zst && \
    echo "$SHASUM archlinux-bootstrap-x86_64.tar.zst" > sha256sum.txt && \
    sha256sum -c sha256sum.txt || exit 1 && \
    tar -xf /archlinux-bootstrap-x86_64.tar.zst --numeric-owner && \
    rm -f /archlinux-bootstrap-x86_64.tar.zst && \
    apk del gnutar zstd curl && \
    apk cache clean

# Start empty layer.
FROM scratch AS system

# Copy the rootfs into the empty layer.
COPY --from=rootfs /root.x86_64/ /

# Taking brew from ublue.
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /

# Putting homebrew in its own layer.
RUN setfattr -n user.component -v "homebrew" "/usr/share/homebrew.tar.zst"

# Enabling pacman mirrors.
RUN sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist

# Replacing pacman.conf with CachyOS defaults.
RUN rm -f /etc/pacman.conf && \
    curl --retry 3 https://raw.githubusercontent.com/CachyOS/docker/refs/heads/master/pacman.conf -o /etc/pacman.conf && \
    curl --retry 3 https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist -o /etc/pacman.d/cachyos-mirrorlist

# Creating pacman log file.
RUN touch /var/log/pacman.log

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Assign user.component to every package scriptlet by Hec & Cleaning up package cache scriplet by Xenia.
RUN mkdir -p /usr/libexec
COPY files/usr/libexec /usr/libexec
COPY files/usr/share /usr/share

# Populate Arch Linux keyring first.
RUN pacman-key --init && \
    pacman-key --populate

# Transitioning to cachyos >:D.
RUN pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key F3B607488DB35A47 && \
    pacman -Sy && \
    pacman -S --needed --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist cachyos-hooks chwd cachyos-rate-mirrors && \
    pacman -Syu --noconfirm && pacman -S --clean --noconfirm

# Add a repo for bootc by hec.
RUN pacman-key --recv-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB && \
    echo -e '[bootc]\nSigLevel = Required\nServer=https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo' >> /etc/pacman.conf

# Chaotic AUR repo
RUN pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
RUN pacman-key --init && pacman-key --lsign-key 3056513887B78AEB
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' --noconfirm
RUN pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' --noconfirm
RUN echo -e '[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf

# Handling dracut errors out on missing i18n_vars https://github.com/dracutdevs/dracut/issues/868.
RUN mkdir -p /usr/lib/dracut/dracut.conf.d && \
    echo 'i18n_vars="/usr/share/kbd/consolefonts  /usr/share/kbd/keymaps"' >> /usr/lib/dracut/dracut.conf.d/bootc-cachy.conf

# Rate mirrors.
RUN cachyos-rate-mirrors

# Installing packages.
## Updating existing packages and cleaning up cache.
RUN pacman -Syu --noconfirm && pacman -S --clean --noconfirm

## Base packages.
RUN pacman -Sy --needed --noconfirm base linux-cachyos linux-cachyos-headers linux-firmware dracut ostree systemd btrfs-progs e2fsprogs xfsprogs binutils dosfstools skopeo dbus dbus-glib glib2 shadow cpio reflector shadow bootc && pacman -S --clean --noconfirm

## Chaotic AUR
RUN pacman -Sy --needed --noconfirm chaotic-aur/niri-git && pacman -S --clean --noconfirm

# Sudo changes for ease of use.
RUN mkdir -p /etc/sudoers.d && \
    echo "%wheel ALL=(ALL) ALL"  \
    Defaults pwfeedback \
    Defaults insults \
    Defaults secure_path="/usr/local/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin" \
    Defaults env_keep += "EDITOR VISUAL PATH" \
    Defaults timestamp_timeout=0' \
    tee "/etc/sudoers.d/wheel"

# Handling Bootc issues # https://github.com/bootc-dev/bootc/issues/1801.
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img"

# Necessary for general behavior expected by image-based systems.
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /mnt /opt /boot /home /root /usr/local /srv /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var /run /tmp && \
    ln -s sysroot/ostree /ostree && ln -s var/roothome /root && ln -s var/srv /srv && ln -s var/opt /opt && ln -s var/mnt /mnt && ln -s var/home /home && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

# Link /etc/os-release to its equivalent in /usr/lib/os-release.
RUN ln -sf ../usr/lib/os-release /etc/os-release

# Linking time.
RUN ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# Containers setup.
RUN
RUN mkdir -p /etc/pki/containers
COPY files/etc /etc
COPY cosign.pub /etc/pki/containers/cosign.pub

# Making bootc compatible https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images.
LABEL containers.bootc 1

RUN bootc container lint
