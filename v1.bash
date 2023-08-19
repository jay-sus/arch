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


# Partition
echo "Creating partitions..."
sgdisk -Z "$target"
sgdisk \
    -n1:0:+512M  -t1:ef00 -c1:EFISYSTEM \
    -N2          -t2:8304 -c2:linux \
    "$target"
# Reload partition table
sleep 2
partprobe -s "$target"
sleep 2
echo "Encrypting root partition..."
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/linux
cryptsetup luksOpen /dev/disk/by-partlabel/linux root
echo "Making File Systems..."
# Create file systems
mkfs.vfat -F32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM
mkfs.ext4 -L linux /dev/mapper/root
# mount the root, and create + mount the EFI directory
echo "Mounting File Systems..."
mount /dev/mapper/root /mnt
mkdir /mnt/efi -p
mount -t vfat /dev/disk/by-partlabel/EFISYSTEM /mnt/efi


echo "[comfy] Updating pacman mirrorlist..."
reflector --country $reflector --age 24 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "[comfy] Installing base package..."
pacstrap -K /mnt

echo "[comfy] Installing essential packages..."
arch-chroot /mnt pacman -Sy "${essential[@]}" --noconfirm --quiet



echo "Setting up environment..."
#set up locale/env
#add our locale to locale.gen
sed -i -e "/^#"$locale"/s/^#//" /mnt/etc/locale.gen
#remove any existing config files that may have been pacstrapped, systemd-firstboot will then regenerate them
rm /mnt/etc/{machine-id,localtime,hostname,shadow,locale.conf} -f
systemd-firstboot --root /mnt \
	--keymap="$keymap" --locale="$locale" \
	--locale-messages="$locale" --timezone="$timezone" \
	--hostname="$hostname" --setup-machine-id \
	--welcome=false
arch-chroot /mnt locale-gen
echo "Configuring for first boot..."
#add the local user
arch-chroot /mnt useradd -G wheel -m "$username"
arch-chroot /mnt passwd "$username"

#uncomment the wheel group in the sudoers file
sed -i -e '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /mnt/etc/sudoers
#create a basic kernel cmdline, we're using DPS so we don't need to have anything here really, but if the file doesn't exist, mkinitcpio will complain
echo "quiet rw" > /mnt/etc/kernel/cmdline
#change the HOOKS in mkinitcpio.conf to use systemd hooks
sed -i \
    -e 's/base udev/base systemd/g' \
    -e 's/keymap consolefont/sd-vconsole sd-encrypt/g' \
    /mnt/etc/mkinitcpio.conf
#change the preset file to generate a Unified Kernel Image instead of an initram disk + kernel
sed -i \
    -e '/^#ALL_config/s/^#//' \
    -e '/^#default_uki/s/^#//' \
    -e '/^#default_options/s/^#//' \
    -e 's/default_image=/#default_image=/g' \
    -e "s/PRESETS=('default' 'fallback')/PRESETS=('default')/g" \
    /mnt/etc/mkinitcpio.d/linux.preset

#read the UKI setting and create the folder structure otherwise mkinitcpio will crash
declare $(grep default_uki /mnt/etc/mkinitcpio.d/linux.preset)
arch-chroot /mnt mkdir -p "$(dirname "${default_uki//\"}")"




#enable the services we will need on start up
echo "Enabling services..."
systemctl --root /mnt enable systemd-resolved systemd-timesyncd NetworkManager sddm
#mask systemd-networkd as we will use NetworkManager instead
systemctl --root /mnt mask systemd-networkd
#regenerate the ramdisk, this will create our UKI
echo "Generating UKI and installing Boot Loader..."
arch-chroot /mnt mkinitcpio -p linux
echo "Setting up Secure Boot..."
if [[ "$(efivar -d --name 8be4df61-93ca-11d2-aa0d-00e098032b8c-SetupMode)" -eq 1 ]]; then
arch-chroot /mnt sbctl create-keys
arch-chroot /mnt sbctl enroll-keys -m
arch-chroot /mnt sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
arch-chroot /mnt sbctl sign -s "${default_uki//\"}"
else
echo "Not in Secure Boot setup mode. Skipping..."
fi
#install the systemd-boot bootloader
arch-chroot /mnt bootctl install --esp-path=/efi
#lock the root account
arch-chroot /mnt usermod -L root
#and we're done


echo "Install complete. Run reeboot!"
sleep 10
sync

) |& tee comfy.log -a

