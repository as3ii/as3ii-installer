# My personal ArchLinux installer
## Usage
- start the live environment
- `pacman -Syu git` to install `git`
- `git clone https://github.com/as3ii/arch3ii-installer.git` to clone this repo
- `cd arch3ii-installer` to navigate inside the downloaded folder
- run `setup-base.sh`

If you want, you can add the device name and the keymap code as parameters

NOTE: running `pacman -Syu git` on an old live environment (even just a few months)
could result in filling of _cowspace_, so you may need to run `mount -o
remount,size=2G /run/archiso/cowspace`

## To Do:
- [ ] add more checks
- [ ] more verbose output
- [ ] grub installation and configuration
