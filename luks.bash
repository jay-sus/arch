#!/bin/bash

# =============== Configuration ===============

target="/dev/sda" # Find your disk with lsblk
ucode="intel-ucode"
locale="en_US.UTF-8"
keymap="us"
editor="nano"
timezone="Europe/London"
reflector="UK,US"
hostname="ARCH"
username=""

basepacks=(
    base # Base packages
    linux # System kernel
    linux-firmware # Drivers for common hardware
    $ucode # Processor microcode
    base-devel # Sudo and useful compilers
    $editor # Your text editor
    lvm2 # Volume manager
    dracut # Boot process automation
    sbsigntools # UEFI signing tools
    iwd # Wireless network tools
    efibootmgr # Manage EFI
    binutils # Manage binary files
    util-linux # Standard utility package
    cryptsetup # Encryption management
    e2fsprogs # Utilities for ext filesystem
    dosfstools # Utilities for fat filesystem
    networkmanager # Network management
)

extrapacks=(
    man-db # Manual
    firefox # Web browser
    git # You're gonna need this
    neofetch # Very important
)

# =============== Pre-run checks ===============

echo "Checking root..."
if [[ "$UID" -ne 0 ]]; then
    echo "This script needs to be run as root!" >&2
    exit 3
fi

echo "Checking configuration..."
if [[ -z "$username" ]]; then
    echo "Configure this script before running!" >&2
    exit 3
fi

echo "Checking internet..."
ping -c 1 "1.1.1.1" &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "Connect to the internet!" >&2
    exit 3
fi

PS3="Run Setup step: "
opts=("Disk partitioning" "OS install" "Boot setup" "Quit")
printopts() {
    ind=1
    for opt in "${opts[@]}" ; do
        echo "$((ind++))) $opt"
    done
}
select opt in "${opts[@]}" ; do
case "$REPLY" in
1) # =============== Disk partitioning ===============

echo "Wiping partition table entries on device $target..."
sgdisk -Z "$target"
sync

echo "Creating partitions (512MB EFI + encrypted LUKS)..."
sgdisk -n1:0:+512M -t1:ef00 -c1:EFISYSTEM -N2 -t2:8309 -c2:LUKS "$target"

echo "Reloading partition table..."
sleep 4
partprobe -s "$target"
sleep 4

echo "Formatting EFI partition..."
mkfs.vfat -F 32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM

echo "Formatting LUKS partition..."
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/LUKS --label LUKS

echo "Opening LUKS partition..."
cryptsetup luksOpen --perf-no_read_workqueue --perf-no_write_workqueue \
    --persistent /dev/disk/by-partlabel/LUKS cryptlvm

echo "Creating volume group vg..."
pvcreate /dev/mapper/cryptlvm
vgcreate vg /dev/mapper/cryptlvm

echo "Creating logical volume root..."
lvcreate -l 100%FREE vg -n root

echo "Formatting root partition..."
mkfs.ext4 -L linux /dev/vg/root

echo "Mounting filesystems..."
mount /dev/vg/root /mnt
mkdir -p /mnt/boot/efi
mount -t vfat /dev/disk/by-partlabel/EFISYSTEM /mnt/boot/efi

printopts
;;
2) # =============== OS install ===============

echo "Updating pacman mirrorlist..."
reflector --country $reflector --age 24 --protocol https \
    --sort rate --save /etc/pacman.d/mirrorlist

echo "Installing base packages..."
pacstrap -K /mnt "${basepacks[@]}"

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Setting timezone and generating /etc/adjtime..."
arch-chroot /mnt ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
arch-chroot /mnt hwclock --systohc

echo "Configuring locale..."
sed -i -e "/^#"$locale"/s/^#//" /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$locale" > /mnt/etc/locale.conf

echo "Configuring keymap..."
echo "KEYMAP=$keymap" > /mnt/etc/vconsole.conf

echo "Configuring hostname..."
echo "$hostname" > /mnt/etc/hostname

echo "Creating local user..."
arch-chroot /mnt useradd -G wheel -m "$username"
arch-chroot /mnt passwd "$username"

echo "Enabling sudo for local user..."
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers

echo "Enabling services for next boot..."
systemctl --root /mnt enable systemd-resolved NetworkManager iwd
systemctl --root /mnt mask systemd-networkd

printopts
;;
3) # =============== Boot setup ===============

echo "Creating dracut scripts..."
cat > /mnt/usr/local/bin/dracut-install.sh << EOF
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
    if [[ "\$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="\${line#'usr/lib/modules/'}"
        kver="\${kver%'/pkgbase'}"
        dracut --force --uefi --kver "\$kver" /boot/efi/EFI/Linux/arch-linux.efi
    fi
done
EOF
cat > /mnt/usr/local/bin/dracut-remove.sh << EOF
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/arch-linux.efi
EOF
arch-chroot /mnt /bin/bash -c "chmod +x /usr/local/bin/dracut-*"

echo "Creating pacman hooks..."
mkdir /mnt/etc/pacman.d/hooks
cat > /mnt/etc/pacman.d/hooks/90-dracut-install.hook << EOF
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
EOF
cat > /mnt/etc/pacman.d/hooks/60-dracut-remove.hook << EOF
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
EOF

echo "Configuring dracut..."
cat > /mnt/etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-$(blkid -s UUID -o value "/dev/disk/by-partlabel/LUKS") rd.lvm.lv=vg/root root=/dev/mapper/vg-root rootfstype=ext4 rootflags=rw,relatime"
EOF
cat > /mnt/etc/dracut.conf.d/flags.config << EOF
compress="zstd"
hostonly="no"
EOF

echo "Disabling mkinitcpio hooks..."
arch-chroot /mnt ln -sf /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
arch-chroot /mnt ln -sf /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook

echo "Generating UKI by reinstallling linux..."
arch-chroot /mnt pacman -S linux

echo "Creating EFI entry..."
efibootmgr -c -d "$target" -p 1 -L "Arch Linux" --index 0 --loader 'EFI\Linux\arch-linux.efi' -u

printopts
;;
4) 
break
;;
*)
continue
;;
esac
done
