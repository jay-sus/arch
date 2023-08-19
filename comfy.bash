#!/bin/bash
( # Output everything to comfy.log

# =============== Configuration ===============

target="/dev/sda"
ucode="intel-ucode"
kernel="linux"
editor="nano"
locale="en_US.UTF-8"
keymap="us"
timezone="Europe/London"
reflector="UK,US"
hostname="comfy"
username=""

essential=(
    $kernel
    $ucode
    $editor
    linux-firmware
    base-devel
    networkmanager
)

# =============== Pre-run checks ===============

echo "[comfy] Checking root..."
if [[ "$UID" -ne 0 ]]; then
    echo "[comfy] This script needs to be run as root!" >&2
    exit 3
fi

echo "[comfy] Checking configuration..."
if [[ -z "$username" ]]; then
    echo "[comfy] Configure this script before running!" >&2
    exit 3
fi

echo "[comfy] Checking internet..."
ping -c 1 "1.1.1.1" &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "[comfy] Connect to the internet!" >&2
    exit 3
fi

# =============== Setup menu ===============

PS3="[comfy] Select action: "
opts=("Partition disk" "Install packages" "Configure system" "Quit")
printopts() {
    ind=1
    for opt in "${opts[@]}" ; do
        echo "$((ind++))) $opt"
    done
}
select opt in "${opts[@]}" ; do
case "$REPLY" in

1) # =============== Disk partitioning ===============

echo "[comfy] Wiping partition table entries on device $target..."
sgdisk -Z "$target"

echo "[comfy] Creating partitions (256MB EFI + encrypted LUKS)..."
sgdisk -n1:0:+256M -t1:ef00 -c1:EFISYSTEM -N2 -t2:8304 -c2:linux "$target"

echo "[comfy] Reloading partition table..."
sleep 2
partprobe -s "$target"
sleep 2

echo "[comfy] Formatting EFI partition..."
mkfs.vfat -F 32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM

echo "[comfy] Formatting LUKS partition..."
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux --batch-mode

echo "[comfy] Opening LUKS partition..."
cryptsetup luksOpen --perf-no_read_workqueue --perf-no_write_workqueue \
    --persistent /dev/disk/by-partlabel/linux root

echo "[comfy] Formatting root partition..."
mkfs.ext4 -L linux /dev/mapper/root

echo "[comfy] Mounting filesystems..."
mount /dev/mapper/root /mnt
mkdir -p /mnt/efi
mount -t vfat /dev/disk/by-partlabel/EFISYSTEM /mnt/efi

printopts
;;
2) # =============== Installing packages ===============

echo "[comfy] Updating pacman mirrorlist..."
reflector --country $reflector --age 24 --protocol https \
    --sort rate --save /etc/pacman.d/mirrorlist

echo "[comfy] Installing base package..."
pacstrap -K /mnt

echo "[comfy] Installing essential packages..."
arch-chroot /mnt pacman -Sy "${essential[@]}" --noconfirm --quiet

printopts
;;
3) # =============== System setup ===============

echo "[comfy] Configuring locale..."
sed -i -e "/^#"$locale"/s/^#//" /mnt/etc/locale.gen

echo "[comfy] Removing pacstrap-generated configs..."
rm /mnt/etc/{machine-id,localtime,hostname,locale.conf} -f

echo "[comfy] Running systemd-firstboot to regenerate configs..."
systemd-firstboot --root /mnt --keymap="$keymap" --locale="$locale" \
	--locale-messages="$locale" --timezone="$timezone" \
	--hostname="$hostname" --setup-machine-id --welcome=false

echo "[comfy] Generating locale..."
arch-chroot /mnt locale-gen

echo "[comfy] Creating local user..."
arch-chroot /mnt useradd -G wheel -m "$username"
arch-chroot /mnt passwd "$username"

echo "[comfy] Enabling sudo for wheel group..."
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers

echo "[comfy] Creating a basic kernel cmdline for mkinitcpio..."
echo "quiet rw" > /mnt/etc/kernel/cmdline

echo "[comfy] Switching hooks in mkinitcpio.conf..."
sed -i \
    -e 's/base udev/base systemd/g' \
    -e 's/keymap consolefont/sd-vconsole sd-encrypt/g' \
    /mnt/etc/mkinitcpio.conf

echo "[comfy] Enabling Unified Kernel Image in preset file..."
sed -i \
    -e '/^#ALL_config/s/^#//' \
    -e '/^#default_uki/s/^#//' \
    -e '/^#default_options/s/^#//' \
    -e 's/default_image=/#default_image=/g' \
    -e "s/PRESETS=('default' 'fallback')/PRESETS=('default')/g" \
    /mnt/etc/mkinitcpio.d/"$kernel".preset

echo "[comfy] Creating folder structure for UKI..."
declare $(grep default_uki /mnt/etc/mkinitcpio.d/"$kernel".preset)
arch-chroot /mnt mkdir -p "$(dirname "${default_uki//\"}")"

echo "[comfy] Enabling services for next boot..."
systemctl --root /mnt enable systemd-resolved systemd-timesyncd NetworkManager
systemctl --root /mnt mask systemd-networkd

echo "[comfy] Generating UKI and installing Boot Loader..."
arch-chroot /mnt mkinitcpio -p $kernel

echo "[comfy] Setting up Secure Boot..."
if [[ "$(efivar -d --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-SetupMode)" -eq 1 ]]; then
arch-chroot /mnt sbctl create-keys
arch-chroot /mnt sbctl enroll-keys -m
arch-chroot /mnt sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
arch-chroot /mnt sbctl sign -s "${default_uki//\"}"
else
echo "Not in Secure Boot setup mode. Skipping..."
fi

echo "[comfy] Installing systemd-boot bootloader..."
arch-chroot /mnt bootctl install --esp-path=/efi

echo "[comfy] Locking root account..."
arch-chroot /mnt usermod -L root

echo "[comfy] Syncing and unmounting..."
sync
umount -R /mnt

echo "[comfy] =============== Setup complete ==============="
echo "[comfy] When you're ready, run reboot"
break

;;
4) 
break
;;
*)
continue
;;
esac
done

) |& tee comfy.log -a