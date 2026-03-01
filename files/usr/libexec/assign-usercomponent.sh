#!/bin/bash

while read -r pkgname; do
    pacman -Qlq "$pkgname" | while read -r filepath; do
        if [[ -f "$filepath" ]]; then
            setfattr -n user.component -v "$pkgname" "$filepath"
        fi
    done
done
