# vps2aosc
A magical script that installs AOSC OS in place of existing Linux installation, mainly for VPSes.

It's still quite immature, and only tested on one specific environment. Tests and enhancements welcomed.

## Usage
Download an AOSC OS bootable tarball, then run `bash vps2aosc.sh /path/to/tarball.tar.xz`.

## Tested environment

- Huawei Cloud kc1.large.2 with Debian preinstalled

## Troubleshoot

### EFI-booted systems
Unmount the ESP if you have only two partitions -- an ESP and a / partition. On usual AOSC OS with Grub installation ESP is not mounted by default, and this script can just find ESP by checking all block devices.

### Problem not listed here
Just report to Issues section of this Git repo.
