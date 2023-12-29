#!/bin/bash

set -e

header_filename='/tmp/gpt_header.img'
efi_partition_filename='/tmp/fat32_partition.img'
ext4_partition_filename='/tmp/ext4_partition.img'
disk_filename='/tmp/disk.raw'
ext4_mount_path='/tmp/ext4'
efi_mount_path='/tmp/fat32'
# TODO: do not assume 2048mb disk/do not hardcode these/get them from gdisk somehow?
disk_size_mb=2048
efi_partition_size_mb=500
header_start_sector=0
header_end_sector=2047
header_num_sectors=$((header_end_sector - header_start_sector + 1))
efi_start_sector=2048
efi_end_sector=1026047
efi_num_sectors=$((efi_end_sector - efi_start_sector + 1))
root_start_sector=1026048
root_end_sector=4192255
root_num_sectors=$((root_end_sector - root_start_sector + 1))

install_prerequisites() {
    brew install dosfstools e2fsprogs gdisk qemu
    # TODO: fuse-ext2 + fuse-t
}

create_drive_file() {
    dd if=/dev/zero of=$disk_filename bs=1M count=$disk_size_mb
}

partition_drive_file() {
    # ef00 = EFI System Partition
    # 8304 = Linux root (x86-64)
    efi_system_partition_type='ef00'
    ext4_partition_type='8304'
    echo -e "o\ny\nn\n\n\n+${efi_partition_size_mb}M\n${efi_system_partition_type}\nn\n\n\n\n${ext4_partition_type}\nw\ny\n" | gdisk $disk_filename
}

extract_partitions() {
    dd if=$disk_filename of=$header_filename bs=512 count=$header_num_sectors skip=$header_start_sector conv=notrunc
    dd if=$disk_filename of=$efi_partition_filename bs=512 count=$efi_num_sectors skip=$efi_start_sector conv=notrunc
    dd if=$disk_filename of=$ext4_partition_filename bs=512 count=$root_num_sectors skip=$root_start_sector conv=notrunc
}

format_partitions() {
    mkfs.fat -F32 -n 'EFI' $efi_partition_filename
    mkfs.ext4 $ext4_partition_filename
}

mount_partitions() {
    mkdir -p $ext4_mount_path
    mkdir -p $efi_mount_path
    hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount $efi_partition_filename
    mounted_image_disk=$(diskutil list | grep 'EFI' | awk '{print $NF}')
    mount -t msdos /dev/$mounted_image_disk $efi_mount_path
    fuse-ext2 $ext4_partition_filename $ext4_mount_path -o rw+,allow_other
}

unmount_partitions() {
    umount $efi_mount_path || true
    umount $ext4_mount_path || true
    mounted_image_disk=$(diskutil list | grep 'EFI' | awk '{print $NF}')
    if [ -n "$mounted_image_disk" ]
    then
        hdiutil detach /dev/$mounted_image_disk || true
    fi
}

prepare_efi_partition() {
    mkdir -p $efi_mount_path/EFI/BOOT
    cp ./assets/refind_x64.efi-0.14.0.2 $efi_mount_path/EFI/BOOT/bootx64.efi
    cp ./assets/vmlinuz-6.1.0-15-amd64 $efi_mount_path/EFI/BOOT/vmlinuz
    cp ./assets/initrd.img-6.1.0-15-amd64 $efi_mount_path/EFI/BOOT/initrd.img
    cp ./config/refind.conf $efi_mount_path/EFI/BOOT/refind.conf
}

prepare_root_partition() {
    # directories
    mkdir $ext4_mount_path/bin
    mkdir $ext4_mount_path/dev
    mkdir $ext4_mount_path/etc
    mkdir $ext4_mount_path/etc/init.d
    mkdir $ext4_mount_path/lib
    mkdir $ext4_mount_path/proc
    mkdir $ext4_mount_path/root
    mkdir $ext4_mount_path/run
    mkdir $ext4_mount_path/sbin
    mkdir $ext4_mount_path/sys
    mkdir $ext4_mount_path/tmp
    mkdir $ext4_mount_path/usr
    mkdir $ext4_mount_path/usr/bin
    mkdir $ext4_mount_path/usr/sbin
    mkdir $ext4_mount_path/usr/share
    mkdir $ext4_mount_path/usr/share/udhcpc
    mkdir $ext4_mount_path/var
    # rsync because can not use cp due to could not copy extended attributes error with FUSE
    rsync -aP ./assets/busybox-1.35.0-x86_64-linux-musl $ext4_mount_path/bin/busybox
    rsync -aP ./config/fstab $ext4_mount_path/etc/fstab
    rsync -aP ./config/hostname $ext4_mount_path/etc/hostname
    rsync -aP ./config/hosts $ext4_mount_path/etc/hosts
    rsync -aP ./config/resolv.conf $ext4_mount_path/etc/resolv.conf
    rsync -aP ./config/passwd $ext4_mount_path/etc/passwd
    rsync -aP ./config/shadow $ext4_mount_path/etc/shadow # openssl passwd -1 1234
    rsync -aP ./config/inittab $ext4_mount_path/etc/inittab
    rsync -aP ./config/rcS $ext4_mount_path/etc/init.d/rcS
    rsync -aP ./config/udhcpc-default.script $ext4_mount_path/usr/share/udhcpc/default.script
    # set executable
    chmod +x $ext4_mount_path/etc/init.d/rcS
    chmod +x $ext4_mount_path/usr/share/udhcpc/default.script
    chmod +x $ext4_mount_path/bin/busybox
    # symbolic links
    ln -sf ../bin/busybox $ext4_mount_path/sbin/init
    ln -sf busybox $ext4_mount_path/bin/mount
    ln -sf busybox $ext4_mount_path/bin/sh
}

rebuild_drive_file() {
    dd if=$header_filename of=$disk_filename bs=512 count=$header_num_sectors seek=$header_start_sector conv=notrunc
    dd if=$efi_partition_filename of=$disk_filename bs=512 count=$efi_num_sectors seek=$efi_start_sector conv=notrunc
    dd if=$ext4_partition_filename of=$disk_filename bs=512 count=$root_num_sectors seek=$root_start_sector conv=notrunc
    rm $header_filename
    rm $efi_partition_filename
    rm $ext4_partition_filename
}

cleanup() {
    rm -rf $efi_mount_path
    rm -rf $ext4_mount_path
    rm -f $disk_filename
    rm -f $header_filename
    rm -f $efi_partition_filename
    rm -f $ext4_partition_filename
    killall Finder # fixes volume icons being messed up all over the place on Desktop from lots of mounting + unmounting
}

run_qemu() {
    # not sure why brew qemu doesn't ship with -x86_64-vars.fd by default
    cp /opt/homebrew/Cellar/qemu/8.1.3_2/share/qemu/edk2-i386-vars.fd /opt/homebrew/Cellar/qemu/8.1.3_2/share/qemu/edk2-x86_64-vars.fd
    qemu-system-x86_64 \
        -m 1024 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/opt/homebrew/Cellar/qemu/8.1.3_2/share/qemu/edk2-x86_64-code.fd \
        -drive if=pflash,format=raw,unit=1,file=/opt/homebrew/Cellar/qemu/8.1.3_2/share/qemu/edk2-x86_64-vars.fd \
        -drive file=$disk_filename,format=raw \
        -nic user,model=virtio-net-pci \
        -nographic
}

unmount_partitions
cleanup
#install_prerequisites
create_drive_file
partition_drive_file
extract_partitions
format_partitions
mount_partitions
prepare_efi_partition
prepare_root_partition
unmount_partitions
rebuild_drive_file
run_qemu
