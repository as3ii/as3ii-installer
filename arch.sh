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
# defaults:
crypt=false
root_path="/mnt"
boot_path="$root_path/boot"
efi_path="$boot_path"
keyboard="en"
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
        -R|--root-dev)
            shift
            root_dev="$1";;
        *)
            print_error "Flag \"$1\" does not exist\n";;
    esac
    shift
done

if [ -z "$device" ]; then
    print_error "-d/--device parameter must be set. Exiting\n"
    exit 1
fi
if [ -z "$root_dev" ]; then
    print_error "-r/--root-dev parameter must be set. Exiting\n"
    exit 1
fi

print_info "Starting ArchLinux installation\n"

# create swapfile system
print_info "Setting swapfile\n"
truncate -s 0 "$root_path"/swap/.swapfile
fallocate -l 2G "$root_path"/swap/.swapfile
chmod 600 "$root_path"/swap/.swapfile
mkswap "$root_path"/swap/.swapfile
swapon "$root_path"/swap/.swapfile
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
pacstrap "$root_path" base linux linux-firmware \
    btrfs-progs man-db man-pages neovim git grub efibootmgr

# generate fstab
print_info "Generating fstab\n"
genfstab -U "$root_path" >> "$root_path"/etc/fstab

# fix fstab
mv "$root_path"/etc/fstab "$root_path"/etc/fstab.old
sed -e 's/subvolid=[0-9]\+\,\?//g' \
    -e 's/relatime/noatime/g' \
    "$root_path"/etc/fstab.old >"$root_path"/etc/fstab

# set crypttab.initramfs
if $crypt; then
    print_info "Creating crypttab\n"
    cp "$root_path"/etc/crypttab "$root_path"/etc/crypttab.initramfs
    printf "cryptroot   UUID=%s   luks,discard\n" "$(lsblk -dno UUID "$root_dev")" \
        >>"$root_path"/etc/crypttab.initramfs
fi

# update mkinitcpio
print_info "Updating mkinitcpio.conf\n"
mv "$root_path"/etc/mkinitcpio.conf "$root_path"/etc/mkinitcpio.conf.old
if $crypt; then
    # shellcheck disable=SC1004
    sed -e 's/^BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/' \
        -e 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard \\\
        sd-vconsole modconf block sd-encrypt filesystems fsck)/' \
        "$root_path"/etc/mkinitcpio.conf.old >"$root_path"/etc/mkinitcpio.conf
else
    # shellcheck disable=SC1004
    sed -e 's/^BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/' \
        -e 's/^HOOKS=(.*)/HOOKS=(base systemd autodetect keyboard \\\
        sd-vconsole modconf block filesystems fsck)/' \
        "$root_path"/etc/mkinitcpio.conf.old >"$root_path"/etc/mkinitcpio.conf
fi

# fix grub config
print_info "Configuring and installing grub\n"
mv "$root_path"/etc/default/grub "$root_path"/etc/default/grub.old
sed -e 's/quiet//' "$root_path"/etc/default/grub.old >"$root_path"/etc/default/grub

# setup grub
if [ -d /sys/firmware/efi/efivars ]; then
    arch-chroot "$root_path" sh -c "\
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; \
        grub-mkconfig -o /boot/grub/grub.cfg"
else
    arch-chroot "$root_path" sh -c "\
        grub-install --target=i386-pc $device; \
        grub-mkconfig -o /boot/grub/grub.cfg"
fi

print_info "Setting keymap, locale and hosts\n"

# set keymap
printf "KEYMAP=%s" "$keyboard" >"$root_path"/etc/vconsole.conf

# set locale
sed 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$root_path"/etc/locale.gen > "$root_path"/etc/locale.gen.new
mv "$root_path"/etc/locale.gen.new "$root_path"/etc/locale.gen
locale-gen
printf "LANG=en_US.UTF-8" >"$root_path"/etc/locale.conf

# localhost
printf "127.0.0.1	localhost\n::1		localhost\n" >"$root_path"/etc/hosts

# regen initcpio
arch-chroot "$root_path" sh -c "mkinitcpio -P"

# set root password
print_info "Setting root password\n"
arch-chroot "$root_path" sh -c "passwd"

# chroot in the installed system and exec install.sh
#arch-chroot "$root_path" install.sh

