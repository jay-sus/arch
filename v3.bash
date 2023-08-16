#!/bin/bash

# uncomment to debug 
#set -xeuo pipefail

# =============== Configuration ===============

target="/dev/sda" # Check with lsblk
ucode="intel-ucode"
locale="en_US.UTF-8"
keymap="us"
timezone="Europe/London"
hostname="ARCH"
username=""
editor="nano"
reflector="UK,US"

basepacks=(
    base # Base packages
    linux # System kernel
    linux-firmware # Drivers for common hardware
    $ucode # Processor microcode
    base-devel # Sudo and compilers
    $editor # Text editor
    lvm2 # Logical volume manager
    dracut # Boot process automation
    sbsigntools # UEFI signing tools
    iwd # Wireless network access
    git # Version control system
    efibootmgr # Manage EFI
    binutils # Manage binary files
    util-linux # Standard utility package
    cryptsetup # Encryption management
    e2fsprogs # Utilities for ext filesystem
    dosfstools # Utilities for fat filesystem
    NetworkManager # Network management
)

extrapacks=(
    man-db # Manual
    firefox # Web Browser
    neofetch # Mandatory
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
    echo "Connect to the internet! (use iwctl for wifi)" >&2
    exit 3
fi

# =============== Disk partitioning ===============

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

# =============== System bootstrap ===============

echo "Updating pacman mirrorlist..."
reflector --country $reflector --age 24 --protocol https \
    --sort rate --save /etc/pacman.d/mirrorlist

echo "Installing base packages..."
pacstrap -K /mnt "${basepacks[@]}"

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Removing and regenerating config files with systemd-firstboot..."
rm /mnt/etc/{machine-id,localtime,hostname,shadow,locale.conf} ||
systemd-firstboot --root /mnt --keymap="$keymap" --locale="$locale" \
    --locale-messages="$locale" --timezone="$timezone" --hostname="$hostname" \
    --setup-machine-id --welcome=false

echo "Adding locale to /etc/locale.gen..."
sed -i -e "/^#"$locale"/s/^#//" /mnt/etc/locale.gen

echo "Generating locales..."
arch-chroot /mnt locale-gen

echo "Generating /etc/adjtime..."
arch-chroot /mnt hwclock --systohc

echo "Creating local user..."
arch-chroot /mnt useradd -G wheel -m "$username" 

echo "Enabling sudo for local user..."
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers

echo "Enabling services for next boot..."
systemctl --root /mnt enable systemd-resolved NetworkManager iwd
systemctl --root /mnt mask systemd-networkd

# =============== UKI and boot entry setup ===============

echo "Creating dracut scripts..."
cat << EOF > /usr/local/bin/dracut-install.sh
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
while read -r line; do
    if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="${line#'usr/lib/modules/'}"
        kver="${kver%'/pkgbase'}"
        dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/arch-linux.efi
    fi
done
EOF
cat << EOF > /usr/local/bin/dracut-remove.sh
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/arch-linux.efi
EOF
chmod +x /usr/local/bin/dracut-*

echo "Creating pacman hooks..."
mkdir /etc/pacman.d/hooks
cat << EOF > /etc/pacman.d/hooks/90-dracut-install.hook
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
cat << EOF > /etc/pacman.d/hooks/60-dracut-remove.hook
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
cat << EOF > /etc/dracut.conf.d/cmdline.conf
kernel_cmdline="rd.luks.uuid=luks-${blkid -s UUID -o value "/dev/disk/by-partlabel/LUKS"} rd.lvm.lv=vg/root root=/dev/mapper/vg-root rootfstype=ext4 rootflags=rw,relatime"
EOF
cat << EOF > /etc/dracut.conf.d/flags.config
compress="zstd"
hostonly="no"
EOF

echo "Disabling mkinitcpio hooks..."
ln -sf /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook
ln -sf /dev/null /etc/pacman.d/hooks/60-mkinitcpio-remove.hook

echo "Generating UKI..."
