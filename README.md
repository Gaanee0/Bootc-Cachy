# CachyOS Handheld edition Bootc

<img width="1280" height="800" alt="Screenshot" src="https://github.com/user-attachments/assets/b763b8a2-cbc1-44ff-ac60-b7788d424363" />

[CachyOS](https://cachyos.org/) Deckify branch repackaged as [bootc](https://bootc-dev.github.io/) image. Yep, it works. Yes, I already tried it on Steam Deck. However there's still some rough edges that this README would go into...

Package list is taken from https://github.com/CachyOS/cachyos-calamares/blob/cachyos-deckify-qt6/src/modules/netinstall/netinstall.yaml, some packages are already doing what's needed like downloading Steam Bootstrap directly from SteamOS repository to use without an internet for a bit (just like on SteamOS!).

Some packages (like Firefox) are excluded from the system while providing alternative methods for getting them like Flatpak and Distrobox. You can still use `pacman` though, but you'd need to run `sudo bootc usroverlay` first (those changes would be lost after reboot/shutdown).

## Known issues

- Image is rechunked with new tool [chunkah](https://github.com/coreos/chunkah), however it's highly experimental and it suffers from [uneven distribution of layers](https://github.com/coreos/chunkah/issues/66) compared to rpm-ostree's [`build-chunked-oci`](https://coreos.github.io/rpm-ostree/build-chunked-oci) function which, you guessed it, can be only used in RPM-based distros, hence is why I chose 256 layers instead of previously picked 96. I would still prefer this over one large layer...
- Speaking of rechunking, bootc (while using its composefs backend, didn't tried it with ostree) seems to not respect already existing layers on the system making you to redownload it all over again. 
- It doesn't boot into Steam Gaming Mode! Bummer, but I believe it's really easy to solve, maybe I'm just missing something. Steam in desktop mode should work tho as seen in screenshot
- It still identifies itself as Arch Linux
- Even if Homebrew is unpacked properly in live system, it doesn't put itself to $PATH
- While mounting external media works, /run mounts them in a way that you can't write to it

## Build

### How to build it (and use it)

Uncomment some commands in `Containerfile` after `Setup a temporary root passwd (changeme) for dev purposes`, then run this command:

```bash
just build-containerfile
```

After it's done you can run this command to generate bootable image:

```bash
just generate-bootable-image
```

You'll get `bootable.img` ready to be used, don't forget to enable EFI support in VM of your choice. Create a new account as usual:

```bash
useradd -m -G wheel -s /bin/bash user
```

Then if you'd like to then switch to hosted OCI image so you can do `sudo bootc update` later on:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/lumaeris/cachyos-deckify-bootc:latest
```

## Thanks to...

- [Bootcrew](https://github.com/bootcrew) contributors for making [Arch-Bootc](https://github.com/bootcrew/arch-bootc) a reality, which this repo is mostly based on
- [Hec](https://github.com/hecknt) for providing [libalpm/pacman hook](files/usr/share/libalpm/hooks/assign-usercomponent.hook) ([script itself](files/usr/libexec/assign-usercomponent.sh)) for assigning packages as `user.component` for chunkah, [a unique way of bootstraping Arch](https://github.com/hecknt/archlinux-bootc/blob/5d1f578837ef8c4d1418ed7490a43a613b1a5d04/Containerfile#L1-L18) instead of using Arch Docker image and prebuilt [Bootc package](https://github.com/hecknt/arch-bootc-pkgs)
