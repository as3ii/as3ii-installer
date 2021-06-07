#!/bin/sh

set -e # exit immediately if a command return non-zero status

print_ok() {
    printf "\e[32m%b\e[0m" "$1"
}

print_info() {
    printf "\e[36m%b\e[0m" "$1"
}

print_error() {
    printf "\e[31m%b\e[0m" "$1"
}


if [ "$USER" != "root" ]; then
    sudo "$0" || (
        print_error "Please run this script as root\n"
        exit 1
    )
    exit 0
fi

if [ -e /mnt/etc/nixos/hardware-configuration.nix ]; then
    print_info "genereting configuration files\n"
    nixos-generate-config --root /mnt
fi

print_info "setting swap if not already set\n"
# shellcheck disable=SC1004
sed -i 's/swapDevices = \[[[:space:]]*\];/\
swapDevices = \[{device = "\/swap\/swapfile"; size = 4000;}\];/' \
    /mnt/etc/nixos/hardware-configuration.nix

nixos-install -j "$(nproc)"

