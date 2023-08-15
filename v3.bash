
# =============== Configuration ===============

target="/dev/sda"
rootmnt="/mnt"
ucode="intel"
locale="en_US.UTF-8"
keymap="us"
timezone="Europe/London"
hostname="ARCH"
username=""
editor="nano"
reflector="UK,US"
basepacks=(
    base # Base packages
    base-devel # Sudo and compilers
    linux # System kernel
    linux-firmware # Drivers for common hardware
    $ucode-ucode # Processor microcode
    util-linux # Standard utility package
    cryptsetup # Encryption management
    e2fsprogs # Utilities for ext filesystem
    dosfstools # Utilities for fat filesystem
    networkmanager # Network management
    iwd # Wireless network access
    lvm2 # Logical volume manager
    $editor # Text editor
    dracut # Boot process automation
    sbsigntools # UEFI signing tools
    git # Version control system
    efibootmgr # Manage EFI
    binutils # Manage binary files
    dhcpcd # DHCP client
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
if [[ $? -eq 0 ]]; then
    echo "Connect to the internet! (use iwctl for wifi)" >&2
    exit 3
fi

# =============== Disk partitioning ===============

echo "Wiping partition table entries on device $target..."
sgdisk -Z "$target"

echo "Creating partitions (512MB EFI + encrypted LUKS)..."
sgdisk -n1:0:+512M -t1:ef00 -c1:EFISYSTEM -N2 -t2:8309 -c2:LUKS "$target"

echo "Reloading partition table..."
sleep 2
partprobe -s "$target"
sleep 2

echo "Formatting EFI partition..."
mkfs.vfat -F 32 -n EFISYSTEM /dev/disk/by-partlabel/EFISYSTEM

echo "Formatting LUKS partition..."
cryptsetup luksFormat --type luks2 /dev/disk/by-partlabel/LUKS
cryptsetup luksOpen --perf-no_read_workqueue --perf-no_write_workqueue --persistent /dev/disk/by-partlabel/LUKS cryptlvm

echo "Creating volume group..."
pvcreate /dev/mapper/cryptlvm
vgcreate vg /dev/mapper/cryptlvm

echo "Creating logical volume..."
lvcreate -l 100%FREE vg -n root

echo "Formatting root partition..."
mkfs.ext4 -L linux /dev/vg/root

echo "Mounting filesystems..."
mount /dev/vg/root "$rootmnt"
mkdir -p "$rootmnt"/boot/efi
mount -t vfat /dev/disk/by-partlabel/EFISYSTEM "$rootmnt"/boot/efi

# =============== System bootstrap ===============

echo "Updating pacman mirrors..."
reflector --country $reflector --age 24 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

echo "Installing base packages..."
pacstrap -K $rootmnt "${basepacks[@]}" 

echo "Generating fstab..."
genfstab -U "$rootmnt" >> "$rootmnt"/etc/fstab

echo "Adding locale to "$rootmnt"/etc/locale.gen..."
sed -i -e "/^#"$locale"/s/^#//" "$rootmnt"/etc/locale.gen

echo "Removing and generating config files with systemd-firstboot..."
rm "$rootmnt"/etc/{machine-id,localtime,hostname,shadow,locale.conf} ||
systemd-firstboot --root "$rootmnt" \
	--keymap="$keymap" --locale="$locale" \
	--locale-messages="$locale" --timezone="$timezone" \
	--hostname="$hostname" --setup-machine-id \
	--welcome=false

echo "Switching process root..."
arch-chroot "$rootmnt"

echo "Generating locales..."
locale-gen

echo "Setting root password..."
passwd

