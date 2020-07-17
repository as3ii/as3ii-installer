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

### Help
if [ -n "$1" ] & [ "$1" = "-h" ] | [ "$1" = "--help" ]; then
    print_info "Usage: $0 '/dev/sdX' 'uk'\n"
    exit
fi

### Device selection
# print device list
print_info "Device list: $(find /dev/ -regex "/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)")\n"
# check if $1 not empty
if [ -n "$1" ]; then
    disk="$1"
    shift
else
    disk=""
fi
# loop as long as $disk is a valid device
while [ -z "$disk" ] || [ ! -e "$disk" ] || \
    ! expr "$disk" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; do
    print_info "Type the device name ('/dev/' required): "
    read -r disk
    [ ! -e "$disk" ] && print_error "This device doesn't exist\n"
    if ! expr "$disk" : '^/dev/\(sd[a-z]\|nvme[0-9]n[0-9]\)$' >/dev/null; then
        print_error "You should type a device name, not a partition name\n"
        disk=""
    fi
done
# check disk and ask if it is correct
sgdisk -p "$disk"
print_info "This device will be wiped, are you sure you want to use this device? [y/N] "
read -r sure
[ "$sure" != 'y' ] && exit


# load keyboard layout
if [ -n "$1" ];then
    lang="$1"
    shift
else
    lang=""
fi
while [ -z "$lang" ] || ! localectl list-keymaps | grep -q "^$lang$"; do
    print_info "Type the keymap code (es. en): "
    read -r lang
done
loadkeys "$lang"
print_ok "Keymap loaded\n"

set -eu

# check internet availability
print_info "checking internet connection...\n"
if ! curl -Ism 5 https://www.archlinux.org >/dev/null; then
    print_error "Internet connection is not working correctly. Exiting\n"
    exit
fi

# enable clock sync
timedatectl set-ntp true

# check efi/bios
if ls /sys/firmware/efi/efivars >/dev/null; then
    efi=true
    print_ok "EFI detected\n"
else
    efi=false
    print_ok "BIOS detected\n"
fi

# partitioning
#  260MiB EFI
#  remaining: Linux Filesystem
sgdisk --zap-all "$disk"
if $efi; then
    sgdisk -n 0:0:+260MiB -t 0:ef00 -c 0:BOOT "$disk"
else
    sgdisk -n 0:0:+260MiB -t 0:ef02 -c 0:BOOT "$disk"
fi
sgdisk -n 0:0:0 -t 0:8309 -c 0:cryptroot "$disk"

# force re-reading the partition table
sync
partprobe "$disk"

# print results
sgdisk -p "$disk"

mkfs.vfat "${disk}1" # BOOT partition

# crypt the other partition and format it in btrfs
cryptsetup --type luks2 luksFormat "${disk}2"
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
print_info "Setting swapfile\n"
truncate -s 0 /mnt/swap/.swapfile
chattr +C /mnt/swap/.swapfile
btrfs property set /mnt/swap/.swapfile compression none
fallocate -l 2G /mnt/swap/.swapfile
chmod 600 /mnt/swap/.swapfile
mkswap /mnt/swap/.swapfile
swapon /mnt/swap/.swapfile

sync

# update local pgp keys
print_info "Updating archlinux keyring\n"
pacman -Sy archlinux-keyring --noconfirm

# update and sort mirrors
print_info "Using 'reflector' to find best mirrors\n"
pacman -Sy reflector --noconfirm
reflector -l 100 -f 10 -p https --sort rate --save /etc/pacman.d/mirrorlist

# install system
print_info "Installing basic system\n"
pacstrap /mnt base linux linux-firmware \
    btrfs-progs man-db man-pages neovim git grub efibootmgr

# generate fstab
print_info "Generating fstab and crypttab\n"
genfstab -U /mnt >> /mnt/etc/fstab

# fix fstab
mv /mnt/etc/fstab /mnt/etc/fstab.old
sed -e 's/subvolid=[0-9]\+\,\?//g' \
    -e 's/relatime/noatime/g' \
    /mnt/etc/fstab.old >/mnt/etc/fstab

# set crypttab.initramfs
cp /mnt/etc/crypttab /mnt/etc/crypttab.initramfs
printf "cryptroot   UUID=%s   luks,discard\n" "$(lsblk -dno UUID "${disk}2")" \
    >>/mnt/etc/crypttab.initramfs

# update mkinitcpio
print_info "Updating mkinitcpio.conf\n"
mv /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.old
sed -e 's/^BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/' \
    -e 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard \\\
    sd-vconsole modconf block sd-encrypt filesystems fsck)/' \
    /mnt/etc/mkinitcpio.conf.old >/mnt/etc/mkinitcpio.conf

# fix grub config
print_info "Configuring and installing grub\n"
mv /mnt/etc/default/grub /mnt/etc/default/grub.old
sed -e 's/quiet//' \
    -e 's/^#GRUB_ENABLE_CRYPTODISK=./GRUB_ENABLE_CRYPTODISK=y/' \
    /mnt/etc/default/grub.old >/mnt/etc/default/grub

# setup grub
if $efi; then
    arch-chroot /mnt sh -c "\
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; \
        grub-mkconfig -o /boot/grub/grub.cfg"
else
    arch-chroot /mnt sh -c "\
        grub-install --target=i386-pc $disk; \
        grub-mkconfig -o /boot/grub/grub.cfg"
fi

# set keymap
printf "KEYMAP=%s" "$lang" >/mnt/etc/vconsole.conf

# set locale
sed 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /mnt/etc/locale.gen > /mnt/etc/locale.gen.new
mv /mnt/etc/locale.gen.new /mnt/etc/locale.gen
locale-gen
printf "LANG=en_US.UTF-8" >/mnt/etc/locale.conf

# localhost
printf "127.0.0.1	localhost\n::1		localhost\n" >/mnt/etc/hosts

# regen initcpio
arch-chroot /mnt sh -c "mkinitcpio -P"

# set root password
arch-chroot /mnt sh -c "passwd"

# chroot in the installed system and exec install.sh
#arch-chroot /mnt install.sh

# end
swapoff /mnt/swap/.swapfile
umount -R /mnt
cryptsetup close cryptroot

print_ok "\nEND\n\n"

