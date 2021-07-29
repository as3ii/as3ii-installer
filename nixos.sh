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

### Parameters management
# defaults:
#crypt=false
root_path="/mnt"
boot_path="$root_path/boot"
#efi_path="$boot_path"
#keyboard="en"
while [ -n "$1" ]; do
    case "$1" in
        # -d|--device)
        #     shift
        #     device="$1";;
        # -e|--efi)
        #     shift
        #     efi_path="$1";;
        # -b|--boot)
        #     shift
        #     boot_path="$1";;
        -r|--root)
            shift
            root_path="$1";;
        # -k|--keyboard)
        #     shift
        #     keyboard="$1";;
        # -c|--crypt)
        #     crypt=true;;
        # -R|--root-dev)
        #     shift
        #     root_dev="$1";;
        *)
            print_error "Flag \"$1\" does not exist\n";;
    esac
    shift
done

# if [ -z "$device" ]; then
#     print_error "-d/--device parameter must be set. Exiting\n"
#     exit 1
# fi
# if [ -z "$root_dev" ]; then
#     print_error "-r/--root-dev parameter must be set. Exiting\n"
#     exit 1
# fi


if [ -e "$root_path"/etc/nixos/hardware-configuration.nix ]; then
    print_info "genereting configuration files\n"
    nixos-generate-config --root "$root_path"
fi

print_info "setting swap if not already set\n"
# shellcheck disable=SC1004
sed -i 's/swapDevices = \[[[:space:]]*\];/\
swapDevices = \[{device = "\/swap\/swapfile"; size = 4000;}\];/' \
    "$root_path"/etc/nixos/hardware-configuration.nix

nixos-install -j "$(nproc)"

