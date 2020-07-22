#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will set up hibernation configuration in the VM.
########################################################################################################
# Source utils.sh
. utils.sh || {
	echo "Error: unable to source utils.sh!"
	echo "TestAborted" > state.txt
	exit 0
}
# Source constants file and initialize most common variables
UtilsInit

# Constants/Globals
# Get distro information
GetDistro

# Get generation: 1/2
GetGuestGeneration

# Hibernation is supported in RHEL-8 since kernel-4.18.0-202. Not supported in RHEL-7.
#if [[ $DISTRO =~ "redhat" ]];then
#	MIN_KERNEL="4.18.0-202"
#	CheckVMFeatureSupportStatus $MIN_KERNEL
#	if [[ $? == 1 ]];then
#		UpdateSummary "Hibernation is supported since kernel-4.18.0-202. Current version: $(uname -r). Skip the test."
#		SetTestStateSkipped
#		exit 0
#	fi
#fi

function Main() {
	basedir=$(pwd)
	if [[ "$DISTRO" =~ "redhat" ]];then
		# RHEL requires bigger disk space for kernel repo and its compilation.
		# This is Azure mnt disk from the host.
		linux_path=/mnt/linux
	else
		linux_path=/usr/src/linux
	fi

	# Prepare swap space
	for key in n p 1 2048 '' t 82 p w
	do
		echo $key >> keys.txt
	done
	LogMsg "Generated the keys.txt file for fdisk commanding"

	cat keys.txt | fdisk /dev/sdc
	LogMsg "$?: Executed fdisk command"
	ret=$(ls /dev/sd*)
	LogMsg "$?: List out /dev/sd* - $ret"

	mkswap /dev/sdc1
	LogMsg "$?: Set up the swap space"

	swapon /dev/sdc1
	LogMsg "$?: Enabled the swap space"
	ret=$(swapon -s)
	LogMsg "$?: Show the swap on information - $ret"

	sw_uuid=$(blkid | grep -i sw | awk '{print $2}' | tr -d " " | sed 's/"//g')
	LogMsg "$?: Found the Swap space disk UUID: $sw_uuid"
	if [[ -z "$sw_uuid" ]];then
		LogErr "Swap space disk UUID is empty. Abort the test."
		SetTestStateAborted
		exit 0
	fi

	chmod 766 /etc/fstab

	echo $sw_uuid none swap sw 0 0 >> /etc/fstab
	LogMsg "$?: Updated /etc/fstab file with swap uuid information"
	ret=$(cat /etc/fstab)
	LogMsg "$?: Displayed the contents in /etc/fstab"

	if [[ $hb_url != "" ]]; then
		LogMsg "Starting Hibernation required packages and kernel build in the VM"
		update_repos

		# Install common packages
		req_pkg="gcc make flex bison git"
		install_package $req_pkg
		LogMsg "$?: Installed the common required packages; $req_pkg"

		case $DISTRO in
			redhat_7|centos_7|redhat_8|centos_8)
				req_pkg="elfutils-libelf-devel ncurses-devel bc elfutils-libelf-devel openssl-devel grub2"
				;;
			suse*|sles*)
				req_pkg="ncurses-devel libopenssl-devel libbtrfs-devel cryptsetup dmraid mdadm cryptsetup dmraid mdadm libelf-devel"
				;;
			ubuntu*)
				req_pkg="build-essential fakeroot libncurses5-dev libssl-dev ccache bc dracut-core"
				;;
			*)
				LogErr "$DISTRO does not support hibernation"
				SetTestStateFailed
				exit 0
				;;
		esac
		install_package $req_pkg
		LogMsg "$?: Installed required packages, $req_pkg"

		# Start kernel compilation
		LogMsg "Clone and compile new kernel from $hb_url to $linux_path"
		git clone $hb_url $linux_path
		LogMsg "$?: Cloned the kernel source repo in $linux_path"

		cd $linux_path

		git checkout $hb_branch
		LogMsg "$?: Changed to $hb_branch"

		if [[ "$DISTRO" =~ "redhat" ]];then
			cp /boot/config* $linux_path/.config
		else
			cp /boot/config*-azure $linux_path/.config
		fi
		LogMsg "$?: Copied the default config file from /boot"
		if [[ "$DISTRO" =~ "redhat" ]];then
			# Commented out CONFIG_SYSTEM_TRUSTED_KEY parameter for redhat kernel compilation
			sed -i -e "s/CONFIG_MODULE_SIG_KEY=/#CONFIG_MODULE_SIG_KEY=/g" $linux_path/.config
			sed -i -e "s/CONFIG_SYSTEM_TRUSTED_KEYRING=/#CONFIG_SYSTEM_TRUSTED_KEYRING=/g" $linux_path/.config
			sed -i -e "s/CONFIG_SYSTEM_TRUSTED_KEYS=/#CONFIG_SYSTEM_TRUSTED_KEYS=/g" $linux_path/.config
			sed -i -e "s/CONFIG_DEBUG_INFO_BTF=/#CONFIG_DEBUG_INFO_BTF=/g" $linux_path/.config
		fi

		yes '' | make oldconfig
		LogMsg "$?: Did oldconfig make file"

		make -j $(getconf _NPROCESSORS_ONLN)
		LogMsg "$?: Compiled the source codes"

		make modules_install
		LogMsg "$?: Installed new kernel modules"

		make install
		LogMsg "$?: Install new kernel"

		cd $basedir

		# Append the test log to the main log files.
		if [ -f $linux_path/TestExecution.log ]; then
			cat $linux_path/TestExecution.log >> $basedir/TestExecution.log
		fi
		if [ -f $linux_path/TestExecutionError.log ]; then
			cat $linux_path/TestExecutionError.log >> $basedir/TestExecutionError.log
		fi
	fi

	if [[ "$DISTRO" =~ "redhat" ]];then
		_entry=$(cat /etc/default/grub | grep 'rootdelay=')
		if [ "$_entry" ]; then
			sed -i -e "s/rootdelay=300/rootdelay=300 resume=$sw_uuid/g" /etc/default/grub
			LogMsg "$?: Updated the /etc/default/grub with resume=$sw_uuid"
		else
			echo GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 resume=$sw_uuid" >> /etc/default/grub
			LogMsg "$?: Added resume=$sw_uuid in /etc/default/grub file"
		fi

		_entry=$(cat /etc/default/grub | grep 'GRUB_HIDDEN_TIMEOUT=')
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_HIDDEN_TIMEOUT=*.*/GRUB_HIDDEN_TIMEOUT=30/g" /etc/default/grub
			LogMsg "$?: Updated GRUB_HIDDEN_TIMEOUT value with 30"
		else
			echo 'GRUB_HIDDEN_TIMEOUT=30' >> /etc/default/grub
			LogMsg "$?: Added GRUB_HIDDEN_TIMEOUT=30 in /etc/default/grub file"
		fi

		_entry=$(cat /etc/default/grub | grep 'GRUB_TIMEOUT=')
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/g" /etc/default/grub
			LogMsg "$?: Updated GRUB_TIMEOUT value with 30"
		else
			echo 'GRUB_TIMEOUT=30' >> /etc/default/grub
			LogMsg "$?: Added GRUB_TIMEOUT=30 in /etc/default/grub file"
		fi

		# VM Gen is 2
		if [[ "$os_GENERATION" == "2" ]];then
			grub_cfg="/boot/efi/EFI/redhat/grub.cfg"
		else
			# VM Gen is 1
			if [ -f /boot/grub2/grub.cfg ]; then
				grub_cfg="/boot/grub2/grub.cfg"
			else
				grub_cfg="/boot/grub/grub.cfg"
			fi
		fi
		grub2-mkconfig -o ${grub_cfg}
		LogMsg "$?: Run grub2-mkconfig -o ${grub_cfg}"

		# Must run dracut -f, or it cannot recover image in boot after hibernation
		dracut -f
		LogMsg "$?: Run dracut -f"
	elif [[ "$DISTRO" =~ "sles" || "$DISTRO" =~ "suse" ]];then
		_entry=$(cat /etc/default/grub | grep 'rootdelay=')
		if [ -n "$_entry" ]; then
			sed -i -e "s/rootdelay=300/rootdelay=300 log_buf_len=200M resume=$sw_uuid/g" /etc/default/grub
			LogMsg "$?: Updated the grub file with resume=$sw_uuid"
		else
			echo GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 log_buf_len=200M resume=$sw_uuid" >> /etc/default/grub
			LogMsg "$?: Added resume=$sw_uuid in the grub file"
		fi

		_entry=$(cat /etc/default/grub | grep 'GRUB_HIDDEN_TIMEOUT=')
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_HIDDEN_TIMEOUT=*.*/GRUB_HIDDEN_TIMEOUT=30/g" /etc/default/grub
			LogMsg "$?: Updated GRUB_HIDDEN_TIMEOUT value with 30"
		else
			echo 'GRUB_HIDDEN_TIMEOUT=30' >> /etc/default/grub
			LogMsg "$?: Added GRUB_HIDDEN_TIMEOUT=30 in /etc/default/grub file"
		fi

		_entry=$(cat /etc/default/grub | grep 'GRUB_TIMEOUT=')
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/g" /etc/default/grub
			LogMsg "$?: Updated GRUB_TIMEOUT value with 30"
		else
			echo 'GRUB_TIMEOUT=30' >> /etc/default/grub
			LogMsg "$?: Added GRUB_TIMEOUT=30 in /etc/default/grub file"
		fi

		# VM Gen is 2
		if [[ "$os_GENERATION" == "2" ]];then
			grub_cfg="/boot/efi/EFI/redhat/grub.cfg"
		else
			# VM Gen is 1
			if [ -f /boot/grub2/grub.cfg ]; then
				grub_cfg="/boot/grub2/grub.cfg"
			else
				grub_cfg="/boot/grub/grub.cfg"
			fi
		fi
		grub2-mkconfig -o ${grub_cfg}
		LogMsg "$?: Run grub2-mkconfig -o ${grub_cfg}"

		_entry1=$(cat /etc/default/grub | grep 'resume=')
		_entry2=$(cat /etc/default/grub | grep 'GRUB_HIDDEN_TIMEOUT=30')
		_entry3=$(cat /etc/default/grub | grep 'GRUB_TIMEOUT=30')
		# Re-validate the entry in the grub file.
		if [ -n "$_entry1" ] && [ -n "$_entry2" ] && [ -n "$_entry3" ]; then
			LogMsg "Successfully updated grub file with all three entries"
		else
			LogErr "$_entry, $_entry2, $_entry3 - Missing config update in grub file"
			SetTestStateAborted
			exit 0
		fi
	else
		# Canonical Ubuntu
		_entry=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'rootdelay=')
		# Change boot kernel parameters in 50-cloudimg-settings.cfg
		# resume= defines the disk partition address where the hibernation image goes in and out.
		# For stress test purpose, we need to increase the log file size bigger like 200MB.
		if [ -n "$_entry" ]; then
			sed -i -e "s/rootdelay=300/rootdelay=300 log_buf_len=200M resume=$sw_uuid/g" /etc/default/grub.d/50-cloudimg-settings.cfg
			LogMsg "$?: Updated the 50-cloudimg-settings.cfg with resume=$sw_uuid"
		else
			_entry=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep GRUB_CMDLINE_LINUX_DEFAULT)
			if [ -n "$_entry" ]; then
				sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ rootdelay=300 log_buf_len=200M resume='$sw_uuid'"/'  /etc/default/grub.d/50-cloudimg-settings.cfg
			else
				echo GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 log_buf_len=200M resume=$sw_uuid" >> /etc/default/grub.d/50-cloudimg-settings.cfg
			fi
			LogMsg "$?: Added resume=$sw_uuid in 50-cloudimg-settings.cfg file"
		fi

		_entry=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'GRUB_HIDDEN_TIMEOUT=')
		# This is the case about GRUB_HIDDEN_TIMEOUT
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_HIDDEN_TIMEOUT=*.*/GRUB_HIDDEN_TIMEOUT=30/g" /etc/default/grub.d/50-cloudimg-settings.cfg
			LogMsg "$?: Updated GRUB_HIDDEN_TIMEOUT value with 30"
		else
			echo 'GRUB_HIDDEN_TIMEOUT=30' >> /etc/default/grub.d/50-cloudimg-settings.cfg
			LogMsg "$?: Added GRUB_HIDDEN_TIMEOUT=30 in 50-cloudimg-settings.cfg file"
		fi

		_entry=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'GRUB_TIMEOUT=')
		# This is the case about GRUB_TIMEOUT
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/g" /etc/default/grub.d/50-cloudimg-settings.cfg
			LogMsg "$?: Updated GRUB_TIMEOUT value with 30"
		else
			echo 'GRUB_TIMEOUT=30' >> /etc/default/grub.d/50-cloudimg-settings.cfg
			LogMsg "$?: Added GRUB_TIMEOUT=30 in 50-cloudimg-settings.cfg file"
		fi

		_entry=$(cat /etc/default/grub.d/40-force-partuuid.cfg | grep 'GRUB_FORCE_PARTUUID=')
		# This is the case about GRUB_FORCE_PARTUUID
		if [ -n "$_entry" ]; then
			sed -i -e "s/GRUB_FORCE_PARTUUID=.*/#GRUB_FORCE_PARTUUID=/g" /etc/default/grub.d/40-force-partuuid.cfg
			LogMsg "$?: Commented out GRUB_FORCE_PARTUUID line"
		fi

		update-grub2
		# Update grup2 configuration
		LogMsg "$?: Ran update-grub2"

		_entry1=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'resume=')
		_entry2=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'GRUB_HIDDEN_TIMEOUT=30')
		_entry3=$(cat /etc/default/grub.d/50-cloudimg-settings.cfg | grep 'GRUB_TIMEOUT=30')
		# Re-validate the entry in the 50-cloudimg-settings.cfg file.
		if [ -n "$_entry1" ] && [ -n "$_entry2" ] && [ -n "$_entry3" ]; then
			LogMsg "Successfully updated 50-cloudimg-settings.cfg file with all three entries"
		else
			LogErr "$_entry, $_entry2, $_entry3 - Missing config update in 50-cloudimg-settings.cfg file"
			SetTestStateAborted
			exit 0
		fi
	fi

	echo "setup_completed=0" >> $basedir/constants.sh
	LogMsg "Main function completed"
}

# main body
Main
cp TestExecution.log Setup-TestExecution.log
cp TestExecutionError.log Setup-TestExecutionError.log
SetTestStateCompleted
exit 0
