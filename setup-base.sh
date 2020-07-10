#!/bin/sh

set -e # exit immediately if a command return non-zero status

### Help
if [ -n "$1" ] & [ "$1" = "-h" ] | [ "$1" = "--help" ]; then
    printf "Usage: %s '/dev/sdX' 'uk'\n" "$0"
    exit
fi

### Device selection
# print device list
printf "Device list: %s\n" "$(find /dev/ -regex "/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)")"
# check if $1 not empty
if [ -n "$1" ]; then
    disk="$1"
    shift
else
    disk=""
fi
# loop as long as $disk is a valid device
while [ -z "$disk" ] & [ ! -e "$disk" ] & \
    expr "$disk" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; do
    printf "Type the device name ('/dev/' required): "
    read -r disk
    [ ! -e "$disk" ] && printf "This device doesn't exist\n"
    if ! expr "$disk" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; then
        printf "You should type a device name, not a partition name\n"
        disk=""
    fi
done
# check disk and ask if it is correct
sgdisk -p "$disk"
printf "This device will be wiped, are you sure you want to use this device? [y/N] "
read -r sure
[ "$sure" != 'y' ] && exit

# load keyboard layout
if [ -n "$1" ];then
    lang="$1"
    shift
else
    lang=""
fi
while [ -z "$lang" ]; do
    printf "Type the 2chars keymap code (es. en): "
    read -r lang
done
loadkeys "$lang"

set -eu

# enable clock sync
timedatectl set-ntp true


# partitioning
#  260MiB EFI
#  remaining: Linux Filesystem
sgdisk --zap-all "$disk"
sgdisk -n 0:0:+260MiB -t 0:ef00 -c 0:EFI "$disk"
sgdisk -n 0:0:0 -t 0:8309 -c 0:cryptroot "$disk"

# force re-reading the partition table
sync
partprobe "$disk"

mkfs.vfat "${disk}1" # EFI partition

# crypt the other partition and format it in btrfs
cryptsetup --type luks1 luksFormat "${disk}2"
cryptsetup open "${disk}2" cryptroot
mkfs.btrfs -L arch --checksum xxhash /dev/mapper/cryptroot

# common mount options
mntopt="autodefrag,space_cache=v2,noatime,compress=zstd:2"

# mount the new btrfs partition with some options
mount -o "$mntopt" /dev/mapper/cryptroot /mnt

# subvolume array
subvolumes="@ @snapshot @home @opt @root @swap @tmp @usr_local \
    @var_cache @var_lib_flatpack @var_lib_libvirt @var_log @var_tmp"

# create root, swap and snapshot subvolumes
for sv in $subvolumes; do
    btrfs subvolume create "/mnt/$sv"
done
sync
umount /mnt

# mount subvolumes
for sv in $subvolumes; do
    if [ "$sv" != "@" ]; then
        mkdir -p "/mnt/$(echo "${sv#@}" | sed 's/_/\//g')"
    fi
    mount -o "$mntopt,subvol=$sv" /dev/mapper/cryptroot \
        "/mnt/$(echo "${sv#@}" | sed 's/_/\//g')"
done

# mount boot/EFI partition
mkdir /mnt/boot
mount "${disk}1" /mnt/boot


# create swapfile system
truncate -s 0 /mnt/swap/.swapfile
chattr +C /mnt/swap/.swapfile
btrfs property set /mnt/swap/.swapfile compression none
fallocate -l 2G /mnt/swap/.swapfile
chmod 600 /mnt/swap/.swapfile
mkswap /mnt/swap/.swapfile
swapon /mnt/swap/.swapfile

sync

# update local pgp keys
pacman -Sy archlinux-keyring

# install system
pacstrap -i /mnt base base-devel linux linux-firmware \
    btrfs-progs man-db man-pages texinfo neovim git

# generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# chroot in the installed system and exec install.sh
#arch-chroot /mnt install.sh

# end
umount /mnt
cryptsetup close cryptroot

