# linux-disk-image-builder
Build a bootable GPT Linux disk image from Mac OS X

## Technologies used

* fuse-t + fuse-ext2 (filesystem in userspace)
* Busybox (shell / userspace)
* musl (libc)
* Linux (kernel)
* rEFInd (bootloader)

## TODO

* do not use debian-live-12.4.0-amd64-standard/live/vmlinuz + initrd (kind of overkill)
* do not use busybox 1.35.0-x86_64-linux-musl (there is no binary to download for 1.36.1)
* do not hardcode disk sector offsets in script
