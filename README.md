# My personal ArchLinux installer
## Usage
- start the live environment
- `curl --proto '=https' -sSfO https://raw.githubusercontent.com/as3ii/arch3ii-installer/master/setup-base.sh` to download the script
- `chattr +x setup-base.sh` to make it executable
- `./setup-base.sh` to execute it

If you want, you can add the device name and the keymap code as parameters

## What setup-base.sh does
This script will wipe the given device, these are the partitions that will be created:
```
1: boot partition
            FS: vfat
            Mount Point: /boot
2: luks2 encrypted partition
            Mount Point: /dev/mapper/cryptroot
    2.1: root partition
            FS: btrfs
            Hash: xxhash
            Mount Point: none
            Mount Options: autodefrag,space_cache=v2,noatime,compress=zstd:2
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
```

## To Do:
- [ ] add more checks
- [x] more verbose output
- [x] grub installation and configuration
