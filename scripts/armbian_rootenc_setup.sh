#!/usr/bin/env bash

PATH="$PATH:/usr/sbin:/sbin"
RED="\e[31;1m" GREEN="\e[32;1m" YELLOW="\e[33;1m" BLUE="\e[34;1m" PURPLE="\e[35;1m" RESET="\e[0m"
PROGNAME=$(basename $0)
TITLE='Armbian Encrypted Root Filesystem Setup'
CONFIG_VARS='
	ARMBIAN_IMAGE
	BOOTPART_LABEL
	ROOTFS_NAME
	DISK_PASSWD
	UNLOCKING_USERHOST
	SERIAL_CONSOLE
	IP_ADDRESS
	NETMASK
	ADD_ALL_MODS
	ADD_MODS
	USE_LOCAL_AUTHORIZED_KEYS
	USB_GADGET
	ETH_DEV
'
STATES='
	card_partitioned
	bootpart_copied
	bootpart_label_created
	rootpart_copied
	target_configured
'
USER_OPTS_INFO="
	NO_CLEANUP                 -  no cleanup of mounts after program run
	FORCE_REBUILD              -  force full rebuild
	FORCE_RECONFIGURE          -  force reconfiguration
	FORCE_REFORMAT_ROOT        -  force reformat of encrypted root partition
	ADD_ALL_MODS               -  add all currently loaded modules to initramfs
	ADD_MODS                   y  add specified modules to initramfs
	USE_LOCAL_AUTHORIZED_KEYS  -  use local 'authorized_keys' file if available
	PARTITION_ONLY             -  partition and create filesystems only
	ERASE                      -  zero boot sector, boot partition and beginning of root partition
	ROOTENC_REUSE_FS           -  reuse existing filesystems (for development only)
	ROOTENC_TESTING            -  developer tweaks
	ROOTENC_PAUSE              -  pause along the way
	ROOTENC_IGNORE_APT_ERRORS  -  continue even if apt update fails
	SERIAL_CONSOLE             -  enable disk unlocking via serial console
	USB_GADGET                 -  enable disk unlocking via SSH over USB (g_ether)
	ETH_DEV                    -  select the network device manually (default: auto)
	VERBOSE                    -  produce verbose output
"
RSYNC_VERBOSITY='--info=progress2'

print_help() {
	echo "  ${PROGNAME^^}: Create an Armbian image with encrypted root filesystem
  USAGE:           $PROGNAME [options] <target device name (e.g. SD card)>
  OPTIONS:   '-h'  Print this help message
             '-C'  Don't perform unmounts or clean up build directory at exit
             '-d'  Produce tons of debugging output
             '-f'  Force reconfiguration of target system
             '-F'  Force a complete rebuild of target system
             '-m'  Add all currently loaded modules to the initramfs (may help
                   fix blank screen on bootup issues)
             '-o'  Add specified modules to the initramfs (comma-separated list)
             '-M'  Mount source and target systems and exit
             '-U'  Unmount source and target systems and exit
             '-p'  Partition and create filesystems only.  Do not copy data
             '-R'  Force reformat of encrypted root partition
             '-s'  Use 'authorized_keys' file from working directory, if available
                   (see below)
             '-v'  Be more verbose
             '-u'  Perform an 'apt upgrade' after each 'apt update'
             '-z'  Erase boot sector and first partition of SD card before partitioning
                   (an extra paranoia step, but it can’t hurt)

  For non-interactive operation, set the following variables in your environment
  or on the command line:

      ARMBIAN_IMAGE      - Armbian image file
      ROOTFS_NAME        - device mapper name of target root filesystem
      IP_ADDRESS         - IP address of target (set to 'dhcp' for dynamic IP
                           or 'none' to disable remote SSH unlocking support)
      NETMASK            - Netmask of target.  Defaults to 255.255.255.0
      BOOTPART_LABEL     - Boot partition label of target
      DISK_PASSWD        - Disk password of target root filesystem
      UNLOCKING_USERHOST - USER@HOST of remote unlocking host
      SERIAL_CONSOLE     - Set this to 'y' to enable disk unlocking from the
                           serial console, or 'n' to disable
      USB_GADGET         - Set this to 'y' to enable disk unlocking via SSH over
                           USB (g_ether), or 'n' to disable
      ETH_DEV            - Select the network device manually (default: auto)


                            INSTRUCTIONS FOR USE

  This script must be invoked as superuser on a running Armbian system.
  Packages will be installed using APT, so the system must be Internet-
  connected and its clock correctly set.

  If remote unlocking via SSH is desired, the unlocking host must be reachable.
  Alternatively, SSH public keys for the unlocking host or hosts may be
  provided in the file 'authorized_keys' in the current directory.  This file
  has the same format as a standard SSH 'authorized_keys' file.

  Architecture of host and target (e.g. 64-bit or 32-bit ARM) must be the same.

  For best results, the host and target hardware should also be identical or
  similar.  Building on a host with more memory than the target, for example,
  may lead to disk unlocking failure on the target.  For most users, who’ll be
  building for the currently-running board, this point is a non-issue.

  1. Place an Armbian boot image file for the target system in the current
     directory.  For best results, the image file should match the Debian
     or Ubuntu release of the host system.

  2. Insert a USB card reader with a blank micro-SD card for the target
     system into the host’s USB port.

  3. Determine the SD card’s device name using 'dmesg' or 'lsblk'.

  4. Invoke the script with the device name as argument.  If any options
     are desired, they must precede the device name.

  If the board has an eMMC, it may be used as the target device instead of
  an SD card.  Depending on your platform, you may need to run ‘armbian-config’
  and select ‘Install to internal storage’ -> ‘Install/Update the bootloader
  on eMMC’ to enable booting from the eMMC." | less
}

pause() {
	echo -ne $GREEN'(Press any key to continue)'$RESET >&$stderr_dup
	read
	no_fmsg=1
}
_debug_pause() { [ "$ROOTENC_PAUSE" ] && pause; true; }
imsg()      { echo -e "$1" >&$stdout_dup; no_fmsg=1; }
imsg_nonl() { echo -ne "$1" >&$stdout_dup; no_fmsg=1; }
tmsg()      {
	no_fmsg=1
	[ "$ROOTENC_TESTING" ] || return 0
	echo -e "$1" >&$stdout_dup
}
warn()      { echo -e "$YELLOW$1$RESET" >&$stdout_dup; no_fmsg=1; }
warn_nonl() { echo -ne "$YELLOW$1$RESET" >&$stdout_dup; no_fmsg=1; }
rmsg()      { echo -e "$RED$1$RESET" >&$stdout_dup; no_fmsg=1; }
gmsg()      { echo -e "$GREEN$1$RESET" >&$stdout_dup; no_fmsg=1; }
pu_msg()    { echo -e "$PURPLE$1$RESET" >&$stdout_dup; no_fmsg=1; }

do_partprobe() {
	if [ "$VERBOSE" ]; then
		partprobe
	else
		partprobe 2>/dev/null
	fi
	no_fmsg=1
}

_show_output() { [ "$VERBOSE" ] || exec 1>&$stdout_dup 2>&$stderr_dup; }
_hide_output() { [ "$VERBOSE" ] || exec &>'/dev/null'; }

bailout() { exit; }
die() {
	echo -e "$RED$1$RESET" >&$stdout_dup
	no_fmsg=1
	exit 1
}

_return_handler() {
	local funcname=${FUNCNAME[1]} exitval=$? res
	if [ "${funcname:0:1}" == '_' -o "$no_fmsg" ]; then
		no_fmsg=
		return 0
	fi
	if [ "$exitval" -eq 0 ]; then res='OK'; else res="False ($exitval)"; fi
	printf "$BLUE%-32s $res$RESET\n" "$funcname" >&$stdout_dup
}

_sigint_handler() {
	warn "\nExiting at user request"
	exit 1
}

_error_handler() {
	local exitval=$?
	warn "$(basename ${BASH_SOURCE[1]}):${BASH_LINENO[0]}: ${FUNCNAME[1]}() failed at command '$BASH_COMMAND'"
	rmsg "$SCRIPT_DESC exiting with error ($exitval)"
}

_do_header() {
	echo
	local reply
	if banner=$(toilet --filter=border --filter=gay --width=80 --font=term "*** $TITLE ***" 2>/dev/null); then
		while read reply; do
			echo -e "             $reply"
		done <<-EOF
			$banner
		EOF
	else
		echo -n '                  '
		echo $TITLE
		echo
	fi
	echo "                      For detailed usage information,"
	echo "                        invoke with the '-h' switch"
	echo
}

_warn_user_opts() {
	local out opt have_optarg text

	while read opt have_optarg text; do
		[ "$opt" ] || continue
		if [ "${!opt}" ]; then
			if [ $have_optarg == 'y' ]; then
				out+="  + $text (${!opt})\n"
			else
				out+="  + $text\n"
			fi
		fi
	done <<<$USER_OPTS_INFO

	if [ "$out" ]; then
		warn      "\n  The following user options are in effect:"
		warn_nonl "${out}"
	fi
}

_set_host_vars() {
	BUILD_DIR='armbian_rootenc_build'
	SRC_ROOT="$BUILD_DIR/src"
	BOOT_ROOT="$BUILD_DIR/boot"
	TARGET_ROOT="$BUILD_DIR/target"
	CONFIG_VARS_FILE="$BOOT_ROOT/.rootenc_config_vars"
	host_distro=$(lsb_release --short --codename)
	host_kernel=$(ls '/boot' | egrep '^vmlinu[xz]') # allow 'vmlinux' or 'vmlinuz'
}

check_sdcard_name_and_params() {
	local dev chk
	dev=$1
	[ "$dev" ] || die "You must supply a device name"
	[ "${dev:0:5}" == '/dev/' ] || dev="/dev/$dev"
	[ -e "$dev" ] || die "$dev does not exist"
	chk="$(lsblk --noheadings --nodeps --list --output=TYPE $dev 2>/dev/null)"
	[ "$chk" != 'disk' -a "$chk" != 'loop' ] && {
		[ "$chk" == 'part' ] && die "$dev is a partition, not a block device!"
		die "$dev is not a block device!"
	}
	local pttype size oversize removable non_removable part_sep
	pttype=$(blkid --output=udev $dev | grep TYPE | cut -d '=' -f2)
	size="$(lsblk --noheadings --nodeps --list --output=SIZE --bytes $dev 2>/dev/null)"
	removable="$(lsblk --noheadings --nodeps --list --output=RM $dev 2>/dev/null)"
	oversize=$([ $size -gt 137438953472 ] && echo 'Size is > 128GiB') || true
	non_removable=$([ $removable -ne 0 ] || echo 'Device is non-removable')
	SD_INFO="$(lsblk --noheadings --nodeps --list --output=VENDOR,MODEL,SIZE $dev 2>/dev/null)"
	SD_INFO=${SD_INFO//  / }
	if [ "$oversize" -o "$non_removable" ]; then
		warn "  $dev ($SD_INFO) doesn’t appear to be an SD card"
		warn "  for the following reasons:"
		if [ "$non_removable" ]; then warn "      $non_removable"; fi
		if [ "$oversize" ]; then warn "      $oversize"; fi
		_user_confirm '  Are you sure this is the device you want to install on?' 'no'
	fi
	SDCARD_DEVNAME=${dev:5}
	[ "${SDCARD_DEVNAME%[0-9]}" == $SDCARD_DEVNAME ] || part_sep='p'
	BOOT_DEVNAME=$SDCARD_DEVNAME${part_sep}1
	ROOT_DEVNAME=$SDCARD_DEVNAME${part_sep}2
	[ "$SDCARD_DEVNAME" ] || die 'You must supply a device name for the SD card!'
	pu_msg "Will write to target $dev ($SD_INFO)"
}

_get_user_var() {
	local var desc dfl prompt pat pat_errmsg vtest cprompt seen_prompt reply redo
	var=$1 desc=$2 dfl=$3 prompt=$4 pat=$5 pat_errmsg=$6 vtest=$7

	[ "$MOUNT_TARGET_ONLY" ] && [[ ! $var =~ ^(DISK_PASSWD|ROOTFS_NAME)$ ]] && {
		eval "$var=$dfl"
		return 0
	}

	if [ "$pat" == 'bool' ]; then READOPTS='-n1' READNL="\n"; else READOPTS='' READNL=''; fi
	while true; do
		if [ -z "${!var}" -o "$seen_prompt" -o "$redo" ]; then
			if [ "$seen_prompt" ]; then
				echo -n "  Enter $desc: "
			else
				cprompt=
				while read reply; do
					cprompt+="  ${reply## }\n"
				done <<-EOF
					$prompt
				EOF
				echo
				if [ "$dfl" ]; then
					printf "${cprompt:0:-2} " "$dfl"
				else
					echo -ne "${cprompt:0:-2} "
				fi
				seen_prompt=1
			fi
			eval "read $READOPTS $var"; echo -ne "$READNL"
		fi
		redo=1
		if [ -z "${!var}" -a "$dfl" ]; then eval "$var=$dfl"; fi
		[ "${!var}" ] || {
			rmsg "  $desc must not be empty"
			continue
		}

		if [ "$pat" ]; then
			local rpat=$pat
			if [ "$pat" == 'bool' ]; then
				rpat='^[ynYN]*$'
				pat_errmsg="You must type 'y' or 'n'"
			fi
			echo "${!var}" | egrep -qi "$rpat" || {
				rmsg "  ${!var}: $pat_errmsg"
				continue
			}
			if [ "$pat" == 'bool' ]; then
				if [[ ${!var} =~ ^[Yy]$ ]]; then eval "$var=yes"; else eval "$var="; fi
			fi
		fi

		if [ "$vtest" ]; then
			$vtest || continue
		fi
		break
	done
}

_check_eth_dev() {
	if [ "$ETH_DEV" ]; then
		ip link show $ETH_DEV || {
			warn "User-selected network device '$ETH_DEV' could not be found"
			_user_confirm "Are you sure you want to continue?" "no"
		}
	fi
}

_get_user_vars() {

	local dq='[0-9]{1,3}'

	_get_user_var 'IP_ADDRESS' 'IP address' '' \
		"Enter the IP address of the target machine.
		Enter 'dhcp' for a dynamic IP or 'none' for no remote SSH unlocking support
		IP address:" \
		"^(dhcp|none|$dq\.$dq\.$dq\.$dq)$" \
		'malformed IP address'
	IP_ADDRESS=${IP_ADDRESS,,}

	[[ $IP_ADDRESS =~ ^(dhcp|none)$ ]] || {
		_get_user_var 'NETMASK' 'netmask' '255.255.255.0' \
			"Enter the netmask of the target machine,
			or hit ENTER for the default (%s): " \
			"^($dq\.$dq\.$dq\.$dq)$" \
			'malformed netmask'
	}

	_get_user_var 'BOOTPART_LABEL' 'boot partition label' 'ARMBIAN_BOOT' \
		"Enter a boot partition label for the target machine,
		or hit ENTER for the default (%s): " \
		'^[A-Za-z0-9_]{1,16}$' \
		"Label must contain no more than 16 characters in the set 'A-Za-z0-9_'"

	_get_user_var 'ROOTFS_NAME' 'root filesystem device name' 'rootfs' \
		"Enter a device name for the encrypted root filesystem,
		or hit ENTER for the default (%s):" \
		'^[a-z0-9_]{1,48}$' \
		"Name must contain no more than 48 characters in the set 'a-z0-9_'" \
		'_test_rootfs_mounted'

	if [ "$MOUNT_TARGET_ONLY" ]; then
		local pw_prompt="Enter disk password:"
	else
		local pw_prompt="Choose a simple disk password for the installation process.
		Once your encrypted system is up and running, you can change
		the password using the 'cryptsetup' command.
		Enter password:"
	fi

	_get_user_var 'DISK_PASSWD' 'disk password' '' "$pw_prompt" \
		'^[A-Za-z0-9_ ]{1,10}$' \
		"Temporary disk password must contain no more than 10 characters in the set 'A-Za-z0-9_ '"

	if [ "$IP_ADDRESS" == 'none' ]; then
		UNLOCKING_USERHOST=
	elif [ -e 'authorized_keys' -a "$USE_LOCAL_AUTHORIZED_KEYS" ]; then
		UNLOCKING_USERHOST=
	else
		_get_user_var 'UNLOCKING_USERHOST' 'USER@HOST' '' \
			"Enter the user@host of the machine you'll be unlocking from:" \
			'\S+@\S+' \
			'malformed USER@HOST' \
			'_test_unlocking_host_available'
	fi

	_get_user_var 'SERIAL_CONSOLE' 'serial console unlocking' '' \
		"Unlock the disk from the serial console.  WARNING: enabling this will
		make it impossible to unlock the disk using the keyboard and monitor,
		though unlocking via SSH will still work.
		Enable unlocking via serial console? (y/n):" \
		'bool'

	_get_user_var 'USB_GADGET' 'disk unlocking via SSH over USB (g_ether)' '' \
		"Unlock the disk via SSH over USB (g_ether).  Enable this only if your board
		supports USB gadget mode, i.e. if it has a USB OTG port. WARNING: enabling this
		will make it impossible to unlock the disk over the Ethernet interface (eth0).
		Enable unlocking via SSH over USB? (y/n):" \
		'bool'

	true
}

_test_rootfs_mounted() {
	[ -e "/dev/mapper/$ROOTFS_NAME" ] && {
		local mnt=$(lsblk --list --noheadings --output=MOUNTPOINT /dev/mapper/$ROOTFS_NAME)
		[ "$mnt" ] && {
			rmsg "  Device '$ROOTFS_NAME' is in use and mounted on $mnt"
			return 1
		}
	}
	return 0
}

_test_unlocking_host_available() {
	local ul_host=${UNLOCKING_USERHOST#*@}
	ping -c1 $ul_host &>/dev/null || {
		rmsg "  Unable to ping host '$ul_host'"
		return 1
	}
}

_test_sdcard_mounted() {
	local chk="$(lsblk --noheadings --list --output=MOUNTPOINT /dev/$SDCARD_DEVNAME)"
	[ -z "$chk" ] || {
		lsblk --output=NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT /dev/$SDCARD_DEVNAME
		die "Device /dev/$SDCARD_DEVNAME has mounted partitions!"
	}
}

get_authorized_keys() {
	if [ -f 'authorized_keys' ]; then
		rm -rf /tmp/armbian_rootenc_build-authorized_keys_file
		mv 'authorized_keys' /tmp/armbian_rootenc_build-authorized_keys_file
		mkdir 'authorized_keys'
		mv /tmp/armbian_rootenc_build-authorized_keys_file 'authorized_keys'
	fi
	[ -e 'authorized_keys' -a "$USE_LOCAL_AUTHORIZED_KEYS" ] || {
		mkdir -p 'authorized_keys'
		rsync "$UNLOCKING_USERHOST:.ssh/id_*.pub" 'authorized_keys'
	}
}

_apt_update() {
	[ "$ROOTENC_IGNORE_APT_ERRORS" ] && set +e
	apt --yes update
	[ "$APT_UPGRADE" ] && apt --yes upgrade
	[ "$ROOTENC_IGNORE_APT_ERRORS" ] && set -e
	true
}

_print_pkgs_to_install() {
	local pkgs pkgs_ssh
	case $1 in
		'host')
			case "$host_distro" in
				bionic|buster|focal|bullseye|jammy|bookworm|noble|trixie)
					pkgs='cryptsetup ed' ;;
				*)
					pkgs='cryptsetup ed'
					warn "Warning: unrecognized host distribution '$host_distro'" ;;
			esac ;;
		'target')
			case "$target_distro" in
				buster|focal|bullseye|jammy|bookworm|noble|trixie)
					pkgs='cryptsetup-initramfs' pkgs_ssh='dropbear-initramfs' ;;
				bionic)
					pkgs='cryptsetup' pkgs_ssh='dropbear-initramfs' ;;
				*)
					pkgs='cryptsetup-initramfs' pkgs_ssh='dropbear-initramfs'
					warn "Warning: unrecognized target distribution '$target_distro'" ;;
			esac
			[ "$IP_ADDRESS" != 'none' ] && pkgs+=" $pkgs_ssh" ;;
	esac
	for i in $pkgs; do
		dpkg -l $i 2>/dev/null | grep -q ^ii || echo $i
	done
}

apt_install_host_pkgs() {
	local pkgs=$(_print_pkgs_to_install 'host')
	[ "$pkgs" ] && {
		_apt_update
		apt --yes install $pkgs
	}
	true
}

create_build_dir() {
	mkdir -p $BUILD_DIR
	mkdir -p $SRC_ROOT
	mkdir -p $BOOT_ROOT
	mkdir -p $TARGET_ROOT
}

umount_target() {
	for i in $BOOT_ROOT $TARGET_ROOT; do
		while mountpoint -q $i; do
			umount -Rl $i
		done
	done
}

remove_build_dir() {
	[ -d $TARGET_ROOT ] && rmdir $TARGET_ROOT
	[ -d $BOOT_ROOT ] && rmdir $BOOT_ROOT
	[ -d $SRC_ROOT ] && rmdir $SRC_ROOT
	[ -d $BUILD_DIR ] && rmdir $BUILD_DIR
	true
}

_get_device_maps() {
	local dm_type=$1 varname="device_maps_$1" dm_name ls mp
	eval "$varname="
	while read dm_name; do
		[ "$dm_name" == 'No devices found' ] && break
		fstype="$(lsblk --noheadings --nodeps -o fstype "/dev/mapper/$dm_name")"
		[ "$fstype" == 'ext4' ] || continue
		ls=$(findmnt -n --source "/dev/mapper/$dm_name" | cut -f 1 -d ' ')
		if [ "$ls" -a "$dm_type" == 'mounted_on_target' ]; then
			while read mp; do
				if [ "${mp: -${#TARGET_ROOT}}" == "$TARGET_ROOT" ]; then
					eval "$varname+='$dm_name '"
				fi
			done <<<"$ls"
		elif [ -z "$ls" -a "$dm_type" == 'unmounted' ]; then
			eval "$varname+='$dm_name '"
		fi
	done <<<$(dmsetup ls | cut -f 1)
	tmsg "$varname=[${!varname}]"
}

_close_device_maps() {
	local dm_type=$1
	local varname="device_maps_${dm_type}"
	for i in ${!varname}; do
		tmsg "closing $i"
		cryptsetup status $i > '/dev/null' && cryptsetup luksClose $i
	done
	true
}

_preclean() {
	close_loopmount
	_get_device_maps 'unmounted'
	_close_device_maps 'unmounted'
	_get_device_maps 'mounted_on_target'
	umount_target
	_close_device_maps 'mounted_on_target'
	remove_build_dir
}

_print_success_msg() {
	gmsg "All done!"
	imsg ""
	imsg "  You may now shut down your board, switch removable media if applicable,"
	imsg "  and restart."
	if [ "$IP_ADDRESS" != "none" ]; then
		imsg ""
		imsg "  To unlock the disk on the target machine, execute the following from the"
		imsg "  unlocking host:"
		imsg ""
		imsg "      ssh -p 2222 root@${IP_ADDRESS/dhcp/TARGET_IP}"
	fi
}

_clean() {
	pu_msg "Cleaning up, please wait..."
	_show_output
	close_loopmount
	_get_device_maps 'mounted_on_target'
	umount_target
	update_config_vars_file
	_close_device_maps 'mounted_on_target'
	[ -e 'authorized_keys' -a -z "$USE_LOCAL_AUTHORIZED_KEYS" ] && shred -u 'authorized_keys'
	remove_build_dir
	[ "$build_success" ] && _print_success_msg
	true
}

get_armbian_image() {
	ARMBIAN_IMAGE="$(echo *.img)"
	[ "$ARMBIAN_IMAGE" != '*.img' ] || {
		die 'No image file found: You must place an Armbian image in the current directory!'
	}
	local count=$(echo "$ARMBIAN_IMAGE" | wc -w)
	[ "$count" == 1 ] || die "More than one image file present!:\n$ARMBIAN_IMAGE"
}

get_partition_info() {
	local cmdout
	cmdout=$(fdisk --list --output='Start' $ARMBIAN_IMAGE)
	partition_table_type=$(echo "$cmdout" | grep '^Disklabel' | cut --delimiter=' ' --fields=3)
	case $partition_table_type in
		'gpt')
			cmdout=$(fdisk --list-details --output='Start,Type-UUID' $ARMBIAN_IMAGE)
			read start_sector partition_type_uuid <<<$(echo "$cmdout" | tail --lines=1)
			;;
		'dos')
			read start_sector <<<$(echo "$cmdout" | tail --lines=1)
			;;
		*) die "$partition_table_type: unrecognized partition table type!" ;;
	esac
	[ $((start_sector % 8)) -eq 0 ] || die "start sector: $start_sector: first partition misaligned!"
	boot_partition_sectors=409600 # 200MB
	pu_msg "Image partition table type: ${partition_table_type^^}"
}

_confirm_user_vars() {
	echo
	echo "  Armbian image:                $ARMBIAN_IMAGE"
	echo "  Target device:                /dev/$SDCARD_DEVNAME ($SD_INFO)"
	echo "  Root filesystem device name:  /dev/mapper/$ROOTFS_NAME"
	echo "  Target IP address:            $IP_ADDRESS"
	[ "$NETMASK" ] && echo "  Target netmask:               $NETMASK"
	echo "  Boot partition label:         $BOOTPART_LABEL"
	echo "  Disk password:                $DISK_PASSWD"
	[ "$UNLOCKING_USERHOST" ] && echo "  unlocking user@host:          $UNLOCKING_USERHOST"
	echo "  Serial console unlocking:     ${SERIAL_CONSOLE:-no}"
	echo "  SSH over USB unlocking:       ${USB_GADGET:-no}"
	echo "  Ethernet device:              ${ETH_DEV:-auto}"
	echo
	_user_confirm '  Are these settings correct?' 'yes'
}

setup_loopmount() {
	LOOP_DEV=$(losetup -f)
	losetup -P $LOOP_DEV $ARMBIAN_IMAGE
	mount ${LOOP_DEV}p1 $SRC_ROOT
}

_umount_with_check() {
	mountpoint -q $1 && umount $1
}

update_config_vars_file() {
	mount "/dev/$BOOT_DEVNAME" $BOOT_ROOT
	_print_config_vars $CONFIG_VARS_FILE
	umount $BOOT_ROOT
}

_print_states() {
	for i in $STATES; do
		echo $i: ${!i}
	done
}

_update_state_from_config_vars() {
	[ -e $CONFIG_VARS_FILE ] || return 0
	local reply
	while read reply; do
		eval "c$reply"
	done <<<$(cat $CONFIG_VARS_FILE)
	local saved_states cfgvar_changed
	saved_states="$(_print_states)"
	cfgvar_changed=
	[ $cARMBIAN_IMAGE != $ARMBIAN_IMAGE ]    && cfgvar_changed+=' ARMBIAN_IMAGE' card_partitioned='n'
	[ $cBOOTPART_LABEL != $BOOTPART_LABEL ]  && cfgvar_changed+=' BOOTPART_LABEL' bootpart_label_created='n'
	[ $cROOTFS_NAME != $ROOTFS_NAME ]        && cfgvar_changed+=' ROOTFS_NAME' target_configured='n'
	[ $cDISK_PASSWD != $DISK_PASSWD ]        && cfgvar_changed+=' DISK_PASSWD' rootpart_copied='n'
	[ "$UNLOCKING_USERHOST" -a "$cUNLOCKING_USERHOST" != "$UNLOCKING_USERHOST" ] && {
		cfgvar_changed+=' UNLOCKING_USERHOST' target_configured='n'
	}
	[ "$cSERIAL_CONSOLE" != "$SERIAL_CONSOLE" ]  && {
		cfgvar_changed+=' SERIAL_CONSOLE' target_configured='n'
	}
	[ $cIP_ADDRESS != $IP_ADDRESS ]          && cfgvar_changed+=' IP_ADDRESS' target_configured='n'
	[ "$cNETMASK" != "$NETMASK" ]            && cfgvar_changed+=' NETMASK' target_configured='n'
	[ "$cADD_ALL_MODS" != "$ADD_ALL_MODS" ]  && cfgvar_changed+=' ADD_ALL_MODS' target_configured='n'
	[ "$cADD_MODS" != "$ADD_MODS" ]          && cfgvar_changed+=' ADD_MODS' target_configured='n'
	[ "$cUSB_GADGET" != "$USB_GADGET" ]      && cfgvar_changed+=' USB_GADGET' target_configured='n'
	[ "$cETH_DEV" != "$ETH_DEV" ]            && cfgvar_changed+=' ETH_DEV' target_configured='n'
	[ "$IP_ADDRESS" -a "$cUSE_LOCAL_AUTHORIZED_KEYS" != "$USE_LOCAL_AUTHORIZED_KEYS" ] && {
		cfgvar_changed+=' USE_LOCAL_AUTHORIZED_KEYS' target_configured='n'
	}

	[ $card_partitioned == 'n' ] && {
		bootpart_copied='n'
		bootpart_label_created='n'
		rootpart_copied='n'
		target_configured='n'
	}
	[ $bootpart_copied == 'n' ] && bootpart_label_created='n'
	[ $rootpart_copied == 'n' ] && target_configured='n'

	[ "$saved_states" != "$(_print_states)" ] && {
		warn "Install state altered due to changed config vars:$cfgvar_changed"
		for i in $STATES; do
			if [ "${!i}" == 'n' ]; then
				imsg "  $i: ${RED}no$RESET"
			else
				imsg "  $i: ${GREEN}yes$RESET"
			fi
		done
		_delete_state_files
	}
	true
}

_add_state_file() {
	local state=$1 cmd=$2
	if [ "$cmd" == 'target' ]; then
		touch "$TARGET_ROOT/boot/.rootenc_install_state/$state"
	else
		[ "$cmd" == 'mount' ] && mount "/dev/$BOOT_DEVNAME" $BOOT_ROOT
		mkdir -p "$BOOT_ROOT/.rootenc_install_state"
		touch "$BOOT_ROOT/.rootenc_install_state/$state"
		[ "$cmd" == 'mount' ] && umount $BOOT_ROOT
	fi
	eval "$state='y'"
	tmsg "added state file '$state'"
}

_delete_state_files() {
	for i in $STATES; do
		local fn="$BOOT_ROOT/.rootenc_install_state/$i"
		[ ${!i} == 'n' -a -e $fn ] && /bin/rm $fn
	done
	true
}

_get_state_from_state_files() {
	for i in $STATES; do
		if [ -e "$BOOT_ROOT/.rootenc_install_state/$i" ]; then
			eval "$i=y"
		else
			eval "$i=n"
		fi
	done
}

_print_state_from_state_files() {
	imsg 'Install state:'
	for i in $STATES; do
		if [ -e "$BOOT_ROOT/.rootenc_install_state/$i" ]; then
			imsg "  $i: ${GREEN}yes$RESET"
		else
			imsg "  $i: ${RED}no$RESET"
		fi
	done
}

check_install_state() {
	for i in $STATES; do eval "$i=n"; done
	if [ "$FORCE_REBUILD" ]; then
		return
	else
		do_partprobe
		lsblk --noheadings --list /dev/$SDCARD_DEVNAME -o 'NAME' | grep -q $BOOT_DEVNAME || return 0
		lsblk --noheadings --list /dev/$BOOT_DEVNAME -o 'FSTYPE' | grep -q 'ext4' || return 0

		mount "/dev/$BOOT_DEVNAME" $BOOT_ROOT
		_get_state_from_state_files
		if [ "$target_configured" == 'y' -a "$FORCE_RECONFIGURE" ]; then
			target_configured='n'
			_delete_state_files
		fi
		_print_state_from_state_files
		_update_state_from_config_vars
		_umount_with_check $BOOT_ROOT
	fi
}

close_loopmount() {
	while mountpoint -q $SRC_ROOT; do
		umount $SRC_ROOT
	done
	for i in $(losetup --noheadings --raw --list -j $ARMBIAN_IMAGE | awk '{print $1}'); do
		losetup -d $i
	done
}

_user_confirm() {
	local prompt1 prompt2 dfl_action reply
	prompt1=$1 dfl_action=$2
	if [ "$dfl_action" == 'yes' ]; then
		prompt2='(Y/n)'
	else
		prompt2='(y/N)'
	fi
	imsg_nonl "$prompt1 $prompt2 "
	read -n1 reply
	[ "$reply" ] && imsg ''
	[ "$dfl_action" == 'yes' -a -z "$reply" ] && return
	[ "$reply" == 'y' -o "$reply" == 'Y' ] && return
	warn "Exiting at user request"
	exit 1
}

erase_boot_sector_and_first_partition() {
	local sectors count
	sectors=$((start_sector + boot_partition_sectors + 100))
	count=$((sectors / 8192 + 1))
	pu_msg "Erasing up to beginning of second partition ($sectors sectors, ${count}M):"
	_show_output
	dd  if=/dev/zero \
		of=/dev/$SDCARD_DEVNAME \
		status=progress \
		bs=$((512*8192)) \
		count=$count
	_hide_output
}

create_partition_label() {
	local label_code
	pu_msg "Creating new partition label on /dev/$SDCARD_DEVNAME"
	case $partition_table_type in 'dos') label_code='o';; 'gpt') label_code='g';; esac
	set +e
	echo -e "$label_code\nw\n" | fdisk "/dev/$SDCARD_DEVNAME"
	set -e
	do_partprobe
}

copy_boot_loader() {
	local bs=4096 skip count
	case $partition_table_type in 'dos') skip=0;; 'gpt') skip=8;; esac # LBA8 (0x8000): boot loader magic string
	count=$((start_sector / 8 - $skip))
	pu_msg "Copying boot loader ($count 4K blocks [$((count*8)) sectors], starting at $skip blocks [$((skip*8)) sectors]):"
	_show_output
	dd if=$ARMBIAN_IMAGE of="/dev/$SDCARD_DEVNAME" status='progress' bs=$bs count=$count skip=$skip seek=$skip
	_hide_output
	do_partprobe
}

_print_config_vars() {
	local outfile=$1
	local data="$(for i in $CONFIG_VARS; do echo "$i='${!i}'"; done)"
	if [ "$outfile" ]; then echo "$data" > $outfile; else echo "$data"; fi
}

create_partitions() {
	local p1_end p2_start cmds1 cmds2 bname rname fstype
	p1_end=$((start_sector + boot_partition_sectors - 1))
	p2_start=$((p1_end + 1))

	case $partition_table_type in
		'gpt')
			cmds1="g\nn\n1\n$start_sector\n$p1_end\nn\n2\n$p2_start\n\n"
			cmds2="t\n1\n$partition_type_uuid\nt\n2\n$partition_type_uuid\n"
			;;
		'dos')
			cmds1="o\nn\np\n1\n$start_sector\n$p1_end\nn\np\n2\n$p2_start\n\n"
			cmds2=""
			;;
	esac

	set +e; trap - ERR # fdisk exits with error if partition table cannot be re-read
	echo -e "${cmds1}${cmds2}w\n" | fdisk "/dev/$SDCARD_DEVNAME"
	set -e; trap '_error_handler' ERR

	do_partprobe

	[ "$VERBOSE" ] && {
		pu_msg 'Done partitioning:'
		fdisk --list "/dev/$SDCARD_DEVNAME"
		imsg ""
	}

	bname="$(lsblk --noheadings --list --output=NAME /dev/$BOOT_DEVNAME)"
	[ "$bname" == $BOOT_DEVNAME ] || die 'Partitioning failed!'

	rname="$(lsblk --noheadings --list --output=NAME /dev/$ROOT_DEVNAME)"
	[ "$rname" == $ROOT_DEVNAME ] || die 'Partitioning failed!'

	# filesystem is required by call to _add_state_file(), so we must create it here
	fstype=$(lsblk --noheadings --list --output=FSTYPE "/dev/$BOOT_DEVNAME")
	[ "$fstype" == 'ext4' -a "$ROOTENC_REUSE_FS" ] || mkfs.ext4 -F "/dev/$BOOT_DEVNAME"
	do_partprobe

	_add_state_file 'card_partitioned' 'mount'
}

_do_partition() {
	imsg "All data on /dev/$SDCARD_DEVNAME ($SD_INFO) will be destroyed!!!"
	_user_confirm 'Are you sure you want to continue?' 'no'
	[ "$ERASE" ] && erase_boot_sector_and_first_partition
	create_partition_label
	copy_boot_loader
	create_partitions
}

copy_system_boot() {
	[ "$PARTITION_ONLY" ] && {
		_add_state_file 'bootpart_copied' 'mount'
		return
	}
	mount "/dev/$BOOT_DEVNAME" $BOOT_ROOT
	pu_msg "Copying files to boot partition:"
	_show_output
	rsync $RSYNC_VERBOSITY --archive $SRC_ROOT/boot/* $BOOT_ROOT
	_hide_output
	[ -e "$BOOT_ROOT/boot" ] || (cd $BOOT_ROOT && ln -s . 'boot')
	_add_state_file 'bootpart_copied'
	umount $BOOT_ROOT
}

create_bootpart_label() {
	e2label "/dev/$BOOT_DEVNAME" "$BOOTPART_LABEL"
	do_partprobe
	_add_state_file 'bootpart_label_created' 'mount'
}

copy_system_root() {
	if [ "$FORCE_REFORMAT_ROOT" ] || ! cryptsetup isLuks "/dev/$ROOT_DEVNAME"; then
		pu_msg "Formatting encrypted root partition:"
		echo -n $DISK_PASSWD | cryptsetup luksFormat "/dev/$ROOT_DEVNAME" '-'
	fi
	echo $DISK_PASSWD | cryptsetup luksOpen "/dev/$ROOT_DEVNAME" $ROOTFS_NAME

	local fstype=$(lsblk --noheadings --list --output=FSTYPE "/dev/mapper/$ROOTFS_NAME")
	[ "$fstype" == 'ext4' -a "$ROOTENC_REUSE_FS" ] || mkfs.ext4 -F "/dev/mapper/$ROOTFS_NAME"

	[ "$PARTITION_ONLY" ] || {
		mount "/dev/mapper/$ROOTFS_NAME" $TARGET_ROOT

		pu_msg "Copying system to encrypted root partition:"
		_show_output
		rsync $RSYNC_VERBOSITY --archive --exclude='boot' --exclude='var/cache/apt/archives' $SRC_ROOT/* $TARGET_ROOT
		_hide_output
		sync

		mkdir -p "$TARGET_ROOT/boot"
		touch "$TARGET_ROOT/root/.no_rootfs_resize"

		umount $TARGET_ROOT
	}

	cryptsetup luksClose $ROOTFS_NAME
	do_partprobe

	_add_state_file 'rootpart_copied' 'mount'
}

mount_target() {
	echo $DISK_PASSWD | cryptsetup luksOpen "/dev/$ROOT_DEVNAME" $ROOTFS_NAME
	mount "/dev/mapper/$ROOTFS_NAME" $TARGET_ROOT
	mount "/dev/$BOOT_DEVNAME" "$TARGET_ROOT/boot"

	local src dest args
	while read src dest args; do
		mount $args $src $TARGET_ROOT/$dest
	done <<-EOF
		udev   dev     -t devtmpfs -o rw,relatime,nosuid,mode=0755
		devpts dev/pts -t devpts
		tmpfs  dev/shm -t tmpfs    -o rw,nosuid,nodev,relatime
		proc   proc    -t proc
		sys    sys     -t sysfs
	EOF
}

_copy_to_target() {
	local fn=$1
	if [ -e $fn ]; then
		echo "Copying '$fn'"
		rm -rf $TARGET_ROOT/$fn
		cat $fn > $TARGET_ROOT/$fn
	else
		imsg "Unable to copy '$fn' to target (file does not exist)"
		false
	fi
}

create_etc_crypttab() {
	local root_uuid="$(lsblk --noheadings --list --nodeps --output=UUID /dev/$ROOT_DEVNAME)"
	echo "$ROOTFS_NAME UUID=$root_uuid none initramfs,luks" > "$TARGET_ROOT/etc/crypttab"
	_display_file "$TARGET_ROOT/etc/crypttab"
}

copy_etc_files() {
	_copy_to_target '/etc/resolv.conf'
	_copy_to_target '/etc/hosts'
	set +e
	_copy_to_target /etc/apt/apt.conf.d/*proxy
	set -e
}

_print_net_dev() {
	local text net_pfx
	text="$(ip --brief link)"
	for net_pfx in eth enp end eno enP enD enO en; do
		grepout="$(echo "$text" | grep ^$net_pfx)" || true
		if [ "$grepout" ]; then
			echo "$grepout" | head --lines=1 | cut --delimiter=' ' --field=1
			return 0
		fi
	done
}

_set_target_vars() {

	target_distro=$(chroot $TARGET_ROOT 'lsb_release' '--short' '--codename')
	target_kernel=$(chroot $TARGET_ROOT 'ls' '/boot' | egrep '^vmlinu[xz]')
	target_armbian_keyring_signed=

	local dfl_eth_dev

	case $target_distro in
		bionic|buster|focal)
			dfl_eth_dev='eth0'
			dropbear_dir='/etc/dropbear-initramfs'
			dropbear_conf='config' ;;
		bullseye|jammy)
			dfl_eth_dev='eth0'
			dropbear_dir='/etc/dropbear/initramfs'
			dropbear_conf='config' ;;
		bookworm|noble|trixie|*)
			dfl_eth_dev='end0'
			dropbear_dir='/etc/dropbear/initramfs'
			dropbear_conf='dropbear.conf'
			target_armbian_keyring_signed='y' ;;
	esac

	host_eth_dev=$(_print_net_dev)

	[ "$host_eth_dev" ] || die 'Unable to find default wired network device'

	if [ "$ETH_DEV" ]; then
		eth_dev=$ETH_DEV
	elif _distros_match; then
		eth_dev=$host_eth_dev
	else
		eth_dev=$dfl_eth_dev
	fi

	imsg "$(printf '%-8s %-28s %s' ''        'Host'       'Target')"
	imsg "$(printf '%-8s %-28s %s' ''        '----'       '------')"
	imsg "$(printf '%-8s %-28s %s' 'distro:' $host_distro $target_distro)"
	imsg "$(printf '%-8s %-28s %s' 'kernel:' $host_kernel $target_kernel)"
	imsg "network device: $YELLOW$eth_dev$RESET"
}

_distros_match() {
	[ $host_distro == $target_distro ]
}

_kernels_match() {
	[ ${host_kernel%.*} == ${target_kernel%.*} ] || return 1
	[ ${host_kernel##*-} == ${target_kernel##*-} ]
}

copy_etc_files_distro_specific() {
	local files='/etc/apt/sources.list /etc/apt/sources.list.d/armbian.list'
	if _distros_match; then
		for i in $files; do _copy_to_target $i; done
	else
		warn 'Warning: host and target distros do not match, attempting to rewrite files:'
		for i in $files; do
			imsg "  rewriting $i"
			if [ "$target_armbian_keyring_signed" -a $(basename $i) == 'armbian.list' ]; then
				repl='deb [signed-by=\/usr\/share\/keyrings\/armbian.gpg] http'
				sed "s/$host_distro/$target_distro/g;s/deb http/$repl/" <$i >$TARGET_ROOT/$i
			else
				sed "s/$host_distro/$target_distro/g" <$i >$TARGET_ROOT/$i
			fi
			_display_file $TARGET_ROOT$i
		done
	fi
}

_display_file() {
	local name text reply
	if [ "$2" ]; then
		name="$1"
		text="$2"
	else
		name=${1#$TARGET_ROOT}
		text="$(cat $1)"
	fi
	hl='────────────────────────────────────────'
	hl="$hl$hl$hl"
	hls=${hl:0:${#name}+1}
	echo "┌─$hls─┐"
	echo "│ $name: │"
	echo "├─$hls─┘"
	echo "$text" | sed 's/^/│ /'
}

edit_armbianEnv() {
	local file=$TARGET_ROOT/$1 text console_arg
	ed $file <<-'EOF'
		g/^\s*rootdev=/d
		g/^\s*console=/d
		g/^\s*bootlogo=/d
		wq
	EOF

	case $SERIAL_CONSOLE in
		'yes') console_arg='serial' ;;
		*)     console_arg='display' ;;
	esac

	text="rootdev=/dev/mapper/$ROOTFS_NAME
console=$console_arg
bootlogo=false"
	echo "$text" >> $file

	_display_file $file
}

edit_extlinux_conf() {
	local file=$TARGET_ROOT/$1 text console_arg
	/bin/cp $SRC_ROOT/$1 $TARGET_ROOT/$1

	case $SERIAL_CONSOLE in
		'yes') console_pat='console=tty1' ;;
		*)     console_pat='console=ttyS\S+' ;;
	esac

	ed --extended-regexp $file <<-EOF
		s/root=\S+/root=\/dev\/mapper\/$ROOTFS_NAME/
		s/$console_pat *//
		wq
	EOF

	if grep -q 'splash plymouth' $file; then
		ed --extended-regexp $file <<-EOF
			s/splash plymouth\S+/splash=verbose/
			wq
		EOF
	fi

	_display_file $file
}

# Add the following lines to '/etc/initramfs-tools/initramfs.conf'. If
# your board’s IP address will be statically configured, substitute the
# correct static IP address after 'IP='.  If it will be configured via
# DHCP, omit the IP line entirely:
edit_initramfs_conf() {
	local file="$TARGET_ROOT/etc/initramfs-tools/initramfs.conf" dev=$eth_dev
	[ "$USB_GADGET" ] && dev='usb0'
	ed $file <<-'EOF'
		g/^\s*IP=/s/^/# /
		g/^\s*DEVICE=/d
		wq
	EOF
	[ "$IP_ADDRESS" == 'dhcp' -o "$IP_ADDRESS" == 'none' ] || {
		echo "IP=$IP_ADDRESS:::$NETMASK::$dev:off" >> $file
	}
	[ "$IP_ADDRESS" == 'none' ] || echo "DEVICE=$dev" >> $file
	_display_file $file
}

edit_initramfs_modules() {
	local modlist file hdr
	[ "$ADD_ALL_MODS" -o "$ADD_MODS" -o "$USB_GADGET" ] && {
		if ! _kernels_match; then
			warn 'Host and target kernels do not match.  Not adding modules to initramfs'
		elif ! _distros_match; then
			warn 'Host and target distros do not match.  Not adding modules to initramfs'
		else
			local g_mods='libcomposite u_ether usb_f_rndis g_ether usb_f_eem'
			[ "$ADD_ALL_MODS" ] && modlist=$(lsmod | cut -d ' ' -f1 | tail -n+2)
			[ "$ADD_MODS" ]     && modlist+=$(echo; for m in ${ADD_MODS//,/ }; do echo $m; done)
			[ "$USB_GADGET" ]   && modlist+=$(echo; for m in $g_mods;          do echo $m; done)
		fi
	}
	file="$TARGET_ROOT/etc/initramfs-tools/modules"
	hdr="# List of modules that you want to include in your initramfs.
# They will be loaded at boot time in the order below.
#
# Syntax:  module_name [args ...]
#
# You must run update-initramfs(8) to effect this change.
#
"
	echo "$hdr$modlist" > $file
	_display_file $file
}

copy_authorized_keys() {
	local dest="$TARGET_ROOT$dropbear_dir"
	mkdir -p $dest
	/bin/cat authorized_keys/* > "$dest/authorized_keys"
	chmod 644 "$dest/authorized_keys"
	_display_file "$dest/authorized_keys"
}

create_fstab() {
	local boot_uuid file text
	boot_uuid="$(lsblk --noheadings --list --output=UUID /dev/$BOOT_DEVNAME)"
	file="$TARGET_ROOT/etc/fstab"
	text="/dev/mapper/$ROOTFS_NAME / ext4 defaults,noatime,nodiratime,commit=600,errors=remount-ro 0 1
UUID=$boot_uuid /boot ext4 defaults,noatime,nodiratime,commit=600,errors=remount-ro 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0"
	echo "$text" > $file
	_display_file $file
}

edit_dropbear_cfg() {
	local dest file text
	dest="$TARGET_ROOT$dropbear_dir"
	file="$dest/$dropbear_conf"
	text='DROPBEAR_OPTIONS="-p 2222"
DROPBEAR=y'
	if [ "$IP_ADDRESS" == 'none' ]; then
		[ -e $file ] && rm -v $file
		true
	else
		mkdir -p $dest
		[ -e $file ] && grep -q '^DROPBEAR_OPTIONS="-p 2222"' $file || echo "$text" >> $file
		_display_file $file
	fi
}

netman_manage_usb0() {
	local file bu_file text
	file="$TARGET_ROOT/etc/NetworkManager/NetworkManager.conf"
	bu_file="$file.rootenc.orig"
	text='
[device]
match-device=interface-name:$eth_dev
managed=0
match-device=interface-name:usb0
managed=1'
	if [ -e $file ]; then
		if [ "$USB_GADGET" ]; then
			grep -q '^match-device=interface-name:usb0' $file || {
				/bin/cp $file $bu_file
				echo "$text" >> $file
			}
		else
			[ -e $bu_file ] && /bin/mv $bu_file $file
		fi
		_display_file $file
	elif [ "$USB_GADGET" ]; then
		warn "$file does not exist, not enabling managed usb0"
	fi
}

ifupdown_config_usb0() {
	local file bu_file text
	file="$TARGET_ROOT/etc/network/interfaces"
	bu_file="$file.rootenc.orig"
	text="\nauto usb0\niface usb0 inet static\n\taddress $IP_ADDRESS\n\tnetmask $NETMASK"
	if [ -e $file ]; then
		if [ "$USB_GADGET" -a "$IP_ADDRESS" != 'dhcp' ]; then
			grep -q '^auto usb0' $file || {
				/bin/cp $file $bu_file
				echo -e "$text" >> $file
			}
			systemctl mask network-manager
		else
			[ -e $bu_file ] && /bin/mv $bu_file $file
			systemctl unmask network-manager
		fi
		_display_file $file
	elif [ "$USB_GADGET" ]; then
		warn "$file does not exist, not configuring static usb0"
	fi
}

create_cryptroot_unlock_sh() {
	local dest file text
	dest="$TARGET_ROOT/etc/initramfs-tools/hooks"
	file="$dest/cryptroot-unlock.sh"
	text='#!/bin/sh
if [ "$1" = "prereqs" ]; then echo "dropbear-initramfs"; exit 0; fi
. /usr/share/initramfs-tools/hook-functions
source="/tmp/cryptroot-unlock-profile"
root_home=$(echo $DESTDIR/root-*)
root_home=${root_home#$DESTDIR}
echo "if [ \"\$SSH_CLIENT\" ]; then /usr/bin/cryptroot-unlock; fi" > $source
copy_file ssh_login_profile $source $root_home/.profile
exit 0'
	mkdir -p $dest
	echo "$text" > $file
	chmod 755 $file
	_display_file $file
}

# begin chroot functions:

_pkg_remove() {
	dpkg -s $1 2>/dev/null | grep ^Status | grep -q installed && apt-get --yes purge $1 || :
}

apt_remove_target_pkgs() {
	[ "$IP_ADDRESS" == 'none' ] && _pkg_remove 'dropbear-initramfs'
	_pkg_remove 'bash-completion'
	_pkg_remove 'command-not-found'
	true
}

apt_install_target_pkgs() {
	local pkgs=$(_print_pkgs_to_install 'target')
	[ "$pkgs" ] && {
		echo "target packages to install: $pkgs"
		local ls1 ls2
		_show_output
		ls1=$(ls -l /boot/initrd.img-*)
# DEBUG:
#		dpkg-reconfigure $pkgs # doesn't work in chroot
#		apt --yes purge $pkgs
#		apt-get --yes --purge autoremove
		dpkg --configure --pending --force-confdef
		_apt_update
		echo 'force-confdef' > /root/.dpkg.cfg
		apt --yes install $pkgs
		rm /root/.dpkg.cfg
		apt --yes autoremove
		ls2=$(ls -l /boot/initrd.img-*)
		[ "$ls1" != "$ls2" ] && initramfs_updated='y'
		_hide_output
	}
	true
}

update_initramfs() {
	[ "$ROOTENC_TESTING" ] && return 0
	_show_output
	local ver=$(echo /boot/vmlinu?-* | sed 's/.boot.vmlinu.-//')
	update-initramfs -k $ver -c
	_hide_output
}

gen_target_ssh_host_keys() {
	ssh-keygen -A
}

check_initramfs() {
	local text chk count
	text="$(lsinitramfs /boot/initrd.img-*)"
	set +e

	chk=$(echo "$text" | grep 'cryptsetup')
	count=$(echo "$chk" | wc -l)
	_display_file "lsinitramfs /boot/initrd.img* | grep 'cryptsetup'" "$chk"
	[ "$count" -gt 5 ] || { echo "$text"; die 'Cryptsetup scripts missing in initramfs image'; }

	[ "$IP_ADDRESS" == 'none' ] || {
		chk=$(echo "$text" | grep 'dropbear')
		count=$(echo "$chk" | wc -l)
		_display_file "lsinitramfs /boot/initrd.img* | grep 'dropbear'" "$chk"
		[ "$count" -gt 5 ] || { echo "$text"; die 'Dropbear scripts missing in initramfs image'; }

		chk=$(echo "$text" | grep 'authorized_keys')
		count=$(echo "$chk" | wc -l)
		_display_file "lsinitramfs /boot/initrd.img* | grep 'authorized_keys'" "$chk"
		[ "$count" -eq 1 ] || { echo "$text"; die 'authorized_keys missing in initramfs image'; }
	}
	set -e
}

configure_target() {
	[ "$PARTITION_ONLY" ] && return
	mount_target
	_set_target_vars
	copy_etc_files
	copy_etc_files_distro_specific
	edit_initramfs_conf
	edit_initramfs_modules
	[ "$IP_ADDRESS" == 'none' ] || copy_authorized_keys
	create_etc_crypttab
	create_fstab
	edit_dropbear_cfg
	netman_manage_usb0
	ifupdown_config_usb0
	[ "$IP_ADDRESS" == 'none' ] || create_cryptroot_unlock_sh
	armbian_env="boot/armbianEnv.txt"
	extlinux_conf="boot/extlinux/extlinux.conf"
	if [ -e $SRC_ROOT/$armbian_env ]; then
		edit_armbianEnv $armbian_env
	elif [ -e $SRC_ROOT/$extlinux_conf ]; then
		edit_extlinux_conf $extlinux_conf
	else
		die "could not find $SRC_ROOT/$armbian_env or $SRC_ROOT/$extlinux_conf"
	fi
	_debug_pause

	_show_output # this must be done before entering chroot
	/bin/cp $0 $TARGET_ROOT
	export 'ROOTFS_NAME' 'IP_ADDRESS' 'target_distro' 'ROOTENC_TESTING' 'ROOTENC_PAUSE' 'ROOTENC_IGNORE_APT_ERRORS' 'APT_UPGRADE'

	chroot $TARGET_ROOT "./$PROGNAME" $ORIG_OPTS 'in_target'

	/bin/cp -a '/etc/resolv.conf' "$TARGET_ROOT/etc" # this could be a symlink
	/bin/rm "$TARGET_ROOT/$PROGNAME"

	_add_state_file 'target_configured' 'target'
}

_set_env_vars() {
	shopt -s extglob
	local name val
	while [ $# -gt 0 ]; do
		name=${1%=?*} val=${1#+([A-Z_])=}
		[ "$name" == "$1" -o "$val" == "$1" ] && die "$1: illegal argument (must be in format 'NAME=value')"
		eval "$name=$val"
		shift
	done
	shopt -u extglob
}

_mount_target_and_exit() {
	setup_loopmount
	mount_target
	_set_target_vars
	rmdir $BOOT_ROOT
	exit
}

# begin execution

set -e

while getopts hCfFmo:MUpRsudvz OPT
do
		case "$OPT" in
			h)  print_help; exit ;;
			C)  NO_CLEANUP='y' ;;
			f)  FORCE_RECONFIGURE='y' ;;
			F)  FORCE_REBUILD='y' ;;
			m)  ADD_ALL_MODS='y' ;;
			o)  ADD_MODS=$OPTARG ;;
			M)  MOUNT_TARGET_ONLY='y' ;;
			U)  UMOUNT_TARGET_ONLY='y' ;;
			p)  PARTITION_ONLY='y' ;;
			R)  FORCE_REFORMAT_ROOT='y' ;;
			s)  USE_LOCAL_AUTHORIZED_KEYS='y' ;;
			u)  APT_UPGRADE='y' ;;
			d)  DEBUG='y' ;&
			v)  VERBOSE='y' RSYNC_VERBOSITY='--verbose' ;;
			z)  ERASE='y' ;;
			*)  exit ;;
		esac
	ORIG_OPTS+="-$OPT $OPTARG "
done

shift $((OPTIND-1))

trap '_return_handler' RETURN
trap '_sigint_handler' INT
trap '_error_handler' ERR

set -o functrace
set -o errtrace

exec {stdout_dup}>&1
exec {stderr_dup}>&2

[ $UID == 0 -o $EUID == 0 ] || die 'This program must be run as root!'
export HOME='/root'

[ "$DEBUG" ] && set -x

ARG1=$1

[ "$ARG1" ] || die 'You must supply a target device name'

shift

_set_env_vars $@

if [ "$ARG1" == 'in_target' ]; then
	SCRIPT_DESC='Target script'
	_hide_output
	[ "$target_distro" == 'bionic' ] && {
		echo 'export CRYPTSETUP=y' > '/etc/initramfs-tools/conf.d/cryptsetup'
	}
	apt_remove_target_pkgs
	apt_install_target_pkgs
	[ "$initramfs_updated" ] || update_initramfs
	gen_target_ssh_host_keys
	check_initramfs
else
	SCRIPT_DESC='Host script'
	_check_eth_dev
	_do_header
	_set_host_vars

	[ "$ARMBIAN_IMAGE" ] || get_armbian_image

	get_partition_info

	apt_install_host_pkgs # _preclean requires cryptsetup
	_preclean

	[ "$UMOUNT_TARGET_ONLY" ] && exit

	check_sdcard_name_and_params $ARG1
	create_build_dir

	[ "$MOUNT_TARGET_ONLY" ] && warn 'Mounting source and target and exiting at user request'

	_get_user_vars
	_test_sdcard_mounted

	[ "$MOUNT_TARGET_ONLY" ] && _mount_target_and_exit

	_warn_user_opts
	_confirm_user_vars

	[ "$IP_ADDRESS" == 'none' ] || get_authorized_keys

	[ "$NO_CLEANUP" ] || trap '_clean' EXIT

	setup_loopmount
	_debug_pause

	check_install_state
	_hide_output

	[ "$card_partitioned" == 'n' ]       && _do_partition
	_debug_pause

	[ "$bootpart_copied" == 'n' ]        && copy_system_boot
	[ "$bootpart_label_created" == 'n' ] && create_bootpart_label
	[ "$rootpart_copied" == 'n' ]        && copy_system_root
	[ "$target_configured" == 'n' ]      && configure_target

	sync
	build_success=1
fi
