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

### Usage
print_usage() {
    printf "\e[31m"
    cat << EOF
Usage: $0 [-d /dev/sdX] [-e /dev/sdXY] [-b /dev/sdXY] [-r /dev/sdXY] [-k uk] [-c]
    -d /dev/sdX         select device to be wiped and formatted
    -e /mnt/boot/efi    select partition or mountpoint to use as EFI
    -b /mnt/boot        select partition or mountpoint to use as Boot
    -r /mnt             select partition or mountpoint to use as Root
    -k uk               select keyboard layout
    -c                  enable root partition encryption with luks2
    Use -e, -b and -r if you have manually created (and optionally formatted and
    mounted) the needed partitions. In this case-d option will be ignored if present
EOF
    printf "\e[0m"
    exit
}

### Help
print_help() {
    print_usage
    printf "\e[31m"
    cat << EOF
This script will wipe the given device, these are the partitions that will be created
1: boot partition
            FS: vfat
            Size: 500M (499M if efi is not detected)
            Mount Point: /boot
2: luks2 encrypted partition (when enabled)
            Mount Point: /dev/mapper/cryptroot
    2.1: root partition
            FS: btrfs
            Size: rest of the disk
            Hash: xxhash
            Mount Point: none
            Mount Options: autodefrag,space_cache=v2,noatime,compress=zstd:2
                           'discard=async' will be added when ssd is detected
            Subvolumes:
                Subolume         : Mount Point       : specific options
                @                : /
                @snapshot        : /snapshot
                @home            : /home
                @opt             : /opt
                @root            : /root
                @swap            : /swap             : nocow
                @tmp             : /tmp              : nocow
                @usr_local       : /usr/local
                @var_cache       : /var/cache        : nocow
                @var_lib_flatpack: /var/lib/flatpack
                @var_lib_libvirt : /var/lib/libvirt  : nocow
                @var_log         : /var/log
                @var_tmp         : /var/tmp          : nocow
EOF
    printf "\e[0m"
    exit
}

if [ "$USER" != "root" ]; then
    sudo "$0" || (
        print_error "Please run this script as root\n"
        exit 1
    )
    exit 0
fi

### Parameters management
crypt=false     # default
while [ -n "$1" ]; do
    case "$1" in
        -d|--device)
            shift
            device="$1";;
        -e|--efi)
            shift
            efi_path="$1";;
        -b|--boot)
            shift
            boot_path="$1";;
        -r|--root)
            shift
            root_path="$1";;
        -k|--keyboard)
            shift
            keyboard="$1";;
        -c|--crypt)
            crypt=true;;
        -h)
            print_usage;;
        *)
            print_help;;
    esac
    shift
done


### Device selection
# print device list
print_info "Device list: $(find /dev/ -regex "/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)")\n"
# loop as long as $device is a valid device
while [ -z "$device" ] || [ ! -e "$device" ] || \
    ! expr "$device" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; do
    print_info "Type the device name ('/dev/' required): "
    read -r device
    [ ! -e "$device" ] && print_error "This device doesn't exist\n"
    if ! expr "$device" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; then
        print_error "You should type a device name, not a partition name\n"
        device=""
    fi
done
# check disk and ask if it is correct
sgdisk -p "$device"
print_info "This device will be wiped, are you sure you want to use this device? [y/N] "
read -r sure
[ "$sure" != 'y' ] && exit


### load keyboard layout
while [ -z "$keyboard" ] || ! localectl list-keymaps | grep -q "^$keyboard$"; do
    print_info "Type the keymap code (es. en): "
    read -r keyboard
done
loadkeys "$keyboard"
print_ok "Keymap loaded\n"

set -eu

### check efi/bios
if [ -d /sys/firmware/efi/efivars ]; then
    efi=true
    print_ok "EFI detected\n"
else
    efi=false
    print_ok "BIOS detected\n"
fi


### check ssh/hdd
if [ "$(cat "/sys/block/$(echo "$device" | sed 's/\/dev\///')/queue/rotational")" -eq "0" ]; then
    ssd=true
    print_ok "SSD detected\n"
else
    ssd=false
    print_ok "HDD detected\n"
fi


### partitioning
#  260MiB EFI
#  remaining: Linux Filesystem
print_info "Partitioning $device\n"
sgdisk --zap-all "$device"
if $efi; then
    sgdisk -n 0:0:+260MiB -t 0:ef00 -c 0:BOOT "$device"
    boot="${device}1"
    root_dev="${device}2"
else
    sgdisk -n 0:0:+1MiB -t 0:ef02 "$device"
    sgdisk -n 0:0:+259MiB -t 0:8304 -c 0:BOOT "$device"
    boot="${device}2"
    root_dev="${device}3"
fi
if $crypt; then
    sgdisk -n 0:0:0 -t 0:8309 -c 0:cryptroot "$device"
else
    sgdisk -n 0:0:0 -t 0:8304 -c 0:root "$device"
fi


# force re-reading the partition table
sync
partprobe "$device"

# print results
sgdisk -p "$device"

### preparing partitions
# boot
print_info "Formatting boot partition\n"
mkfs.vfat "$boot" # BOOT partition

# crypt root partition
if $crypt; then
    print_info "Setting luks2 partition\n"
    cryptsetup --type luks2 luksFormat "$root_dev"
    cryptsetup open "$root_dev" cryptroot
    root="/dev/mapper/cryptroot"
else
    root="$root_dev"
fi

# formatting root partition using btrfs
print_info "Formatting root in btrfs\n"
mkfs.btrfs -L arch --checksum xxhash "$root"

# common mount options
mntopt="autodefrag,space_cache=v2,noatime,compress=zstd:2"
mntopt_nocow="autodefrag,space_cache=v2,noatime,nocow"
if $ssd; then
    mntopt="$mntopt,discard=async"
    mntopt_nocow="$mntopt,discard=async"
fi

# mount the new btrfs partition with some options
mount -o "$mntopt" "$root" /mnt

# subvolume array
subvolumes="@ @snapshot @home @opt @root @usr_local @var_log"
subvolumes_nocow="@swap @tmp @var_cache @var_tmp"

# create root, swap and snapshot subvolumes
print_info "Creating subvolumes\n"
for sv in $subvolumes; do
    btrfs subvolume create "/mnt/$sv"
done
for sv in $subvolumes_nocow; do
    btrfs subvolume create "/mnt/$sv"
done
sync
umount /mnt

print_info "Mounting subvolumes\n"
# mount subvolumes
for sv in $subvolumes; do
    dir="/mnt/$(echo "${sv#@}" | sed 's/_/\//g')"
    if [ "$sv" != "@" ]; then
        mkdir -p "$dir"
    fi
    mount -o "$mntopt,subvol=$sv" "$root" "$dir"
done

# mount subvolumes with nocow
for sv in $subvolumes_nocow; do
    dir="/mnt/$(echo "${sv#@}" | sed 's/_/\//g')"
    if [ "$sv" != "@" ]; then
        mkdir -p "$dir"
    fi
    mount -o "$mntopt_nocow,subvol=$sv" "$root" "$dir"
    chattr +C -R "$dir"
done

# mount boot/EFI partition
mkdir /mnt/boot
mount "$boot" /mnt/boot


# start installation script
os_id="$(grep '^ID=' /etc/os-release | sed "s/ID=//")"
if [ "$os_id" = "arch" ]; then
    flag_c=""
    if $crypt; then
        flag_c="-c"
    fi
    if ! [ -e ./arch.sh ]; then
        curl --proto '=https' -sSfO \
            https://raw.githubusercontent.com/as3ii/as3ii-installer/master/arch.sh
        chmod u+x arch.sh
    fi
    ./arch.sh "$flag_c" -k "$keyboard" -d "$device" -r "$root_dev"
fi


# end
print_info "Unmounting\n"
swapoff /mnt/swap/.swapfile
umount -R /mnt
if $crypt; then
    cryptsetup close cryptroot
fi

print_ok "\nEND\n\n"

