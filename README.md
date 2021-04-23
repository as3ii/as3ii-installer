# My personal ArchLinux installer
## Usage
- start the live environment
- `curl --proto '=https' -sSfO https://raw.githubusercontent.com/as3ii/arch3ii-installer/master/setup-base.sh` to download the script
- `chattr +x setup-base.sh` to make it executable
- `./setup-base.sh` to execute it

If you want, you can pass some parameters:
- `-d '/dev/sdX'` to select the device
- `-k 'uk'` for keyboard layout
- `-c` to enable luks2 encryption


## What setup-base.sh does
This script will wipe the given device, these are the partitions that will be created:
```
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
                @var_log         : /var/log
                @var_tmp         : /var/tmp          : nocow
```
Then it will create swapfile, update archlinux-keyring, update pacman's mirrors list,
install base system (`base` `linux` `linux-firmware` `btrfs-progs` `man-db` `man-pages`
`neovim` `git` `grub` `efibootmgr`), generate fstab and crypttab, configure mkinitcpio,
configure and install grub, and setting some base things such as keymap and locale.


## To Do:
- [ ] add more checks
- [ ] add more options for more customizability
- [ ] add zram
- [x] more verbose output
- [x] grub installation and configuration
- [ ] rEFInd installation and configuration
- [x] make luks's cryptography optional
- [ ] /boot encryption
- [ ] snapshot after installation
- [ ] post-base-install script download & launch
