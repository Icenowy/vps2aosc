#! /bin/bash -e

VERBOSE=0

# Option parse
TARBALL="$1"

# Sanity check start
if [ "$(id -u)" != "0" ]; then
	echo "Please run this script as root!" >&2
	exit 1
fi

if [ -d /vps2aosc ]; then
	echo "Warning: /vps2aosc exists, either you created it or a previous vps2aosc session is interrupted." >&2
	echo "Abort now. Please remove this directory to continue." >&2
	exit 1
fi

if [ -d /etc/netplan ]; then
	echo "This system uses netplan. Support for netplan is still TODO now." >&2
	echo "Abort now. It's suggested to reinstall to Debian to use this script." >&2
	exit 1
fi

if [ -d /etc/netctl ]; then
	echo "This system uses netctl. Support for netctl is still TODO now." >&2
	echo "Abort now. It's suggested to reinstall to Debian to use this script." >&2
	exit 1
fi

if [ -e /etc/network/interfaces ] && ! (cat /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null | grep -q 'dhcp'); then
	echo "This system uses ifupdown with static IP. Support for ifupdown static IP is still TODO now." >&2
	echo "Abort now. Please report to the script's author." >&2
	exit 1
fi

if [ "$(cat /proc/mounts | grep -q '^/dev' | wc -l)" -gt 1 ]; then
	echo "This system uses multiple partitions. Support for this is still TODO now." >&2
	echo "Abort now." >&2
	exit 1
fi

if cat /proc/mounts | grep -q '/dev/mapper'; then
	echo "This system uses LVM. Support for this is still TODO now." >&2
	echo "Abort now." >&2
	exit 1
fi

if [ "$(file -i "$TARBALL" | cut -d : -f 2-)" != " application/x-xz; charset=binary" ]; then
	echo "The tarball specified is not a XZ-compressed file." >&2
	echo "Until the script is written, all tarballs released by AOSC are XZ-compressed." >&2
	echo "Please recheck." >&2
	exit 1
fi

if [ "$(ls /home | wc -l)" -gt 1 ]; then
	echo "Multiple users found. It's not supported now." >&2
	echo "Abort now." >&2
	exit 1
fi
# Sanity check end


# Preparation and backup start
# Create our workspace
mkdir -p /vps2aosc

# Back up tarball, because it may get deleted after
cp "$TARBALL" /vps2aosc/tarball.tar.xz

# Extract the tarball to our workspace
cd /vps2aosc
tar x$( (($VERBOSE)) && echo "v" || true )fpJ tarball.tar.xz

# Transfer files
for i in /etc/localtime /etc/hostname /etc/locale.conf
do
	[ -e $i ] || continue
	cp -a /etc/localtime /etc/hostname etc/
done

# Transfer network configuration
if [ "$(find /etc/NetworkManager/system-connections 2>/dev/null | wc -l)" -gt 1 ]; then
	(($VERBOSE)) && echo "Found NetworkManager connections."
	cp /etc/NetworkManager/system-connections/* etc/NetworkManager/system-connections/
elif [ -e /etc/network/interfaces ]; then
	(($VERBOSE)) && echo "Found ifupdown, assume DHCP now, do nothing."
else
	echo "Unknown network configuration system. Abort." >&2
	rm -rf /vps2aosc
	exit 1
fi

# Transfer SSH host keys
cp /etc/ssh/ssh_host* etc/ssh/

# Backup SSH configuration
cp /etc/ssh/sshd_config etc/ssh/sshd_config.bkp

# Backup shadow, for password restoration
cp /etc/shadow etc/shadow.bkp

# Transfer user SSH files
[ -d /root/.ssh ] && cp -r /root/.ssh root/ || true
if [ "$(ls /home | wc -l)" = 1 ]; then
	mkdir -p home/aosc
	cp -r /home/*/.ssh home/aosc/
fi

# Transfer runtime DNS configuration
cp -L /etc/resolv.conf etc/

# Set the name of the ordinary user
username="$(ls /home)"

# Check GRUB installation device if needed
if [ ! -d /sys/firmware/efi ]; then
	grub_dev=""
	for i in /dev/sda* /dev/vda* /dev/mmcblk*
	do
		if dd if="$i" bs=512 count=1 | grep -q 'GRUB '; then
			grub_dev="$i"
			break
		fi
	done
	if [ "$grub_dev" = "" ]; then
		echo "No known GRUB installation device. Abort." >&2
		rm -rf /vps2aosc
		exit 1
	fi
fi
# Preparation and backup end


# Black magic start
# Bind mount
mount -o bind / mnt

# Declare a shortcut to our magic
temp_run() {
	/vps2aosc/lib/ld-*.so --library-path /vps2aosc/usr/lib "$@"
}

# Remove things
for i in /vps2aosc/mnt/*
do
	case "$(temp_run /vps2aosc/usr/bin/basename "$i")" in
	vps2aosc|lost+found)
		continue
		;;
	esac
	temp_run /vps2aosc/usr/bin/rm -rf $i 2>/dev/null || true
done

# Extract the new system in-place
temp_run /vps2aosc/usr/bin/xz -d < /vps2aosc/tarball.tar.xz | temp_run /vps2aosc/usr/bin/tar x$( (($VERBOSE)) && echo "v" )fp - -C /

# Prepare for execution inside the new system
hash -r
export PATH=/usr/bin
# Black magic end


# Restoration start
if [ "$username" = "" ]; then
	# Root only, remove the ordinary user
	userdel -f -r aosc 2>/dev/null || true
	groupdel aosc 2>/dev/null || true
else
	# Ensure we have an ordinary user
	useradd -m aosc 2>/dev/null || true
	usermod -a -G wheel aosc 2>/dev/null || true

	# Transfer back ordinary user .ssh files
	cp -r /vps2aosc/home/aosc/.ssh /home/aosc
	chown -R aosc:aosc /home/aosc
	# Rename our ordinary user to expect name
	usermod -d /home/"$username" -m -l "$username" -p "$(cat /vps2aosc/etc/shadow.bkp | grep "^$username:" | cut -d : -f 2)" aosc
fi

# Transfer back root .ssh files
if [ -d /vps2aosc/root/.ssh ]; then
	cp -r /vps2aosc/root/.ssh /root/
fi

# Set root password
usermod -p "$(cat /vps2aosc/etc/shadow.bkp | grep "^root:" | cut -d : -f 2)" root

# Transfer PermitRootLogin option from host sshd_config
if grep -q "^PermitRootLogin" /vps2aosc/etc/ssh/sshd_config.bkp; then
	tmp="$(mktemp -u)"
	cp /etc/ssh/sshd_config "$tmp"
	grep -B 1000000 "^\#PermitRootLogin" "$tmp" | head -n -1 > /etc/ssh/sshd_config
	grep "^PermitRootLogin" /vps2aosc/etc/ssh/sshd_config.bkp >> /etc/ssh/sshd_config
	grep -A 1000000 "^\#PermitRootLogin" "$tmp" | tail -n +1 >> /etc/ssh/sshd_config
	rm "$tmp"
fi

# Transfer back SSH keys
cp /vps2aosc/etc/ssh/ssh_host* /etc/ssh/

# Transfer back network configuration
cp -r /vps2aosc/etc/NetworkManager/system-connections /etc/NetworkManager/

# Transfer back DNS configuration
cp /vps2aosc/etc/resolv.conf /etc/

# Restoration done

# Install bootloader start
# Switch to a specified mirror if wanted
if [ "$MIRROR" ]; then
	apt-gen-list m "$MIRROR"
fi

# Ensure GRUB is installed
[ -e /usr/bin/grub-install ] || (apt-get update && (apt-get install -y grub || apt-get -f install))

if [ -d /sys/firmware/efi ]; then
	# EFI boot
	esp="$(env LC_ALL=C fdisk -l | grep 'EFI System$' | head -n 1 | awk '{print $1}')"
	mkdir -p /efi
	mount "$esp" /efi
	grub-install --efi-directory=/efi
else
	# Legacy boot
	grub-install "$grub_dev"
fi

# Create grub.cfg
grub-mkconfig -o /boot/grub/grub.cfg
# Install bootloader done

echo "Done. You can do what you want now to furtherly setup the system now, but"
echo "it's recommended to do more things after reboot because it will be more"
echo "stable."
echo
echo "Run \`sync && reboot -f\` to reboot the system. The -f parameter is"
echo "necessary because you can no longer communicate with the host init."
