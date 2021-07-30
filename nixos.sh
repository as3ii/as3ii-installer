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
    sudo "$0" "$@" || exit 1
    exit 0
fi

### Parameters management
# defaults:
#crypt=false
root_path="/mnt"
# boot_path="$root_path/boot"
# efi_path="$boot_path"
# keyboard="en"
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

hwconf_path="$root_path/etc/nixos/hardware-configuration.nix"

if ! [ -e "$hwconf_path" ]; then
    print_info "genereting configuration files\n"
    nixos-generate-config --root "$root_path"
fi

# btrfs configs
_root="$(grep -A4 'fileSystems\."/" =' "$hwconf_path")"
if echo "$_root" | grep 'fsType = "btrfs"'; then
    print_info "add xxhash kernel module if missing in hardware-configuration.nix\n"
    grep -q "boot\.initrd\.availableKernelModules = \[.*xxhash.*\];" "$hwconf_path" || \
        sed -i '/boot\.initrd\.availableKernelModules = \[/ s/\];/"xxhash" \];/' \
            "$hwconf_path"

    _uuid="$(
        echo "$_root" | \
            grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    )"

    print_info "add mount options for btrfs root filesystem\n"
    subvolumes_nocow="@swap @tmp @var_cache @var_tmp"
    # base mount options
    grep -A3 "$_uuid" "$hwconf_path" | grep -o '"subvol=@[a-z]*"' | \
        while read -r i; do
            sed -i "/$i/ s/\];/\"autodefrag\" \"space_cache=v2\" \"noatime\" \"compress=zstd:2\" \];/" \
                "$hwconf_path"
        done
    # nocow subvolumes
    for i in $subvolumes_nocow; do
        n="$(grep -A3 "$_uuid" "$hwconf_path" | grep -n "\"subvol=$i\"" | cut -d: -f1)"
        if [ -n "$n" ]; then
            sed -i "${n}s/compress=zstd:2/nocow/" "$hwconf_path"
        fi
    done
fi

print_info "add mount options to subvolumes\n"

print_info "setting swap if not already set\n"
# shellcheck disable=SC1004
sed -i 's/swapDevices = \[[[:space:]]*\];/\
swapDevices = \[{device = "\/swap\/swapfile"; size = 4000;}\];/' \
    "$root_path"/etc/nixos/hardware-configuration.nix

nixos-install -j "$(nproc)"

