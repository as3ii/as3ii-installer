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

### Parameters management
crypt=false     # default
while [ -n "$1" ]; do
    case "$1" in
        -d|--device)
            shift
            device="$1";;
        -k|--keyboard)
            shift
            keyboard="$1";;
        -c|--crypt)
            crypt=true;;
        -r|--root-dev)
            shift
            root_dev="$1";;
        *)
            print_error "Flag \"$1\" does not exist";;
    esac
    shift
done


print_info "Starting ArchLinux installation\n"

# create swapfile system
print_info "Setting swapfile\n"
truncate -s 0 /mnt/swap/.swapfile
fallocate -l 2G /mnt/swap/.swapfile
chmod 600 /mnt/swap/.swapfile
mkswap /mnt/swap/.swapfile
swapon /mnt/swap/.swapfile
sync

### check internet availability
print_info "Checking internet connection...\n"
if ! curl -Ism 5 https://www.archlinux.org >/dev/null; then
    print_error "Internet connection is not working correctly. Exiting\n"
    exit
fi

### enable clock sync
timedatectl set-ntp true

### base installation
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
print_info "Generating fstab\n"
genfstab -U /mnt >> /mnt/etc/fstab

# fix fstab
mv /mnt/etc/fstab /mnt/etc/fstab.old
sed -e 's/subvolid=[0-9]\+\,\?//g' \
    -e 's/relatime/noatime/g' \
    /mnt/etc/fstab.old >/mnt/etc/fstab

# set crypttab.initramfs
if $crypt; then
    print_info "Creating crypttab"
    cp /mnt/etc/crypttab /mnt/etc/crypttab.initramfs
    printf "cryptroot   UUID=%s   luks,discard\n" "$(lsblk -dno UUID "$root_dev")" \
        >>/mnt/etc/crypttab.initramfs
fi

# update mkinitcpio
print_info "Updating mkinitcpio.conf\n"
mv /mnt/etc/mkinitcpio.conf /mnt/etc/mkinitcpio.conf.old
if $crypt; then
    sed -e 's/^BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/' \
        -e 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard \\\
        sd-vconsole modconf block sd-encrypt filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf.old >/mnt/etc/mkinitcpio.conf
else
    sed -e 's/^BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/' \
        -e 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard \\\
        sd-vconsole modconf block filesystems fsck)/' \
        /mnt/etc/mkinitcpio.conf.old >/mnt/etc/mkinitcpio.conf
fi

# fix grub config
print_info "Configuring and installing grub\n"
mv /mnt/etc/default/grub /mnt/etc/default/grub.old
sed -e 's/quiet//' /mnt/etc/default/grub.old >/mnt/etc/default/grub

# setup grub
if [ -d /sys/firmware/efi/efivars ]; then
    arch-chroot /mnt sh -c "\
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; \
        grub-mkconfig -o /boot/grub/grub.cfg"
else
    arch-chroot /mnt sh -c "\
        grub-install --target=i386-pc $device; \
        grub-mkconfig -o /boot/grub/grub.cfg"
fi

print_info "Setting keymap, locale and hosts"

# set keymap
printf "KEYMAP=%s" "$keyboard" >/mnt/etc/vconsole.conf

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
print_info "Setting root password\n"
arch-chroot /mnt sh -c "passwd"

# chroot in the installed system and exec install.sh
#arch-chroot /mnt install.sh

