#!/bin/bash
# SCRIPT_PURPOSE: Automate and provide examples of KVM workflows.

# NOTE that there are other debug permutations around running kernel(debug)/initrd that
#  I did not get in to. That's left for future need/expansion.


# If you are using the ONIE DUE container
# https://github.com/CumulusNetworks/DUE
#
# 1 - Start the container  with:
#  due --run --dockerarg --privileged --mount-dir /dev:/dev
#  ... and select the ONIE container.
# This will allow loopback mounting a filesystem, but note that
#  with --privileged, you can now damage the HOST system's dev directory.
#
# 2 - then run this script from onie/build-config
#

if [ "$( basename $(pwd) )" != "encryption" ];then
    echo ""
    echo "ERROR! Script must be run from encryption directory. Exiting."
    echo ""
    exit 1
fi

ONIE_TOP_DIR=$( realpath $(pwd)/..)


if [ "$1" = "--debug" ];then
    echo "Enabling top level --debug"
    # and we'll hide that argument
    shift
    set -x
fi

ONIE_MACHINE_TARGET="kvm_x86_64"
#ONIE_MACHINE_TARGET="cumulus_vx"
#MACHINEROOT_DIR="MACHINEROOT=../../machine/cumulus"
#MACHINEROOT_DIR="MACHINEROOT=../machine/kvm_x86_64"
MACHINE_BUILD_TARGET="MACHINE=${ONIE_MACHINE_TARGET}"

# If true, defaults set in fxnApplyDefaults are set.
# Leave unset to specify everything on the command line.
APPLY_HARDCODE_DEFAULTS="TRUE"


# If TRUE, pause after each stage
DO_INTERACTIVE="FALSE"


BUILD_DIR="${ONIE_TOP_DIR}/build"
#
# Directory of files that gets turned into a USB mountable drive
# when the KVM is run.
#
USB_XFER_DIR="${BUILD_DIR}/usb-xfer"


# Store all KVM running related files here
KVM_DIR="${ONIE_TOP_DIR}/kvm"

# Path to the USB image We'll stuff the whole world in here
USB_IMG=${KVM_DIR}/usb-drive
# ...which is why it's 256MB
#USB_SIZE="256M"
# Supersize it for installer debug
USB_SIZE="4G"

# mount point in host for loopback
USB_MNT_DIR="${ONIE_TOP_DIR}/usb-mount"

# Virtual drive to install on
HARD_DRIVE=${KVM_DIR}/onie-${ONIE_MACHINE_TARGET}-demo.qcow2

# Size in GB of virtual drive
HARD_DRIVE_SIZE=5

#Preserve the initial state of the drive so installs can
# be re-run without having to rebuild.
CLEAN_HARD_DRIVE=${KVM_DIR}/onie-${ONIE_MACHINE_TARGET}-clean.qcow2

# Store a configured copy of UEFI bios settings
# Ex: a file configured with keys, but with the
#  ONIE and NOS boot entries removed, to simuluate
#  booting in to hardware with a programmed BIOS
CONFIGURED_OVMF_VARS=${SAFE_PLACE}/configured-OVMF_VARS.fd

# Edit this if you are not building in a DUE container
# Open Virtual Machine Firmware
UEFI_BIOS_SOURCE=/usr/share/ovmf/OVMF.fd

# Local copy of UEFI BIOS used by the ONIE build
UEFI_BIOS=${KVM_DIR}/OVMF.fd


# File for storing set UEFI variables
UEFI_BIOS_SOURCE_VARS=/usr/share/OVMF/OVMF_VARS.fd
UEFI_BIOS_VARS="${KVM_DIR}/OVMF_VARS.fd"

# File for storing set UEFI variables
UEFI_BIOS_SOURCE_CODE=/usr/share/OVMF/OVMF_CODE.fd
UEFI_BIOS_CODE="${KVM_DIR}/OVMF_CODE.fd"

#
# Include Secure Boot functions, which use some of the above
# variables.
#

#. ../../machine/cumulus/cumulus_vx/scripts/kvm-secure.lib
. ./encryption-tool.lib


# A universal error checking function. Invoke as:
# fxnEC <command line> || exit 1
# Example:  fxnEC cp ./foo /home/bar || exit 1
function fxnEC ()
{

    # actually run the command
    "$@"

    # save the status so it doesn't get overwritten
    status=$?
    # Print calling chain (BASH_SOURCE) and lines called from (BASH_LINENO) for better debug
    if [ $status -ne 0 ];then
        #echo "ERROR [ $status ] in ${BASH_SOURCE[1]##*/}, line #${BASH_LINENO[0]}, calls [ ${BASH_LINENO[*]} ] command: \"$*\"" 1>&2
        echo "ERROR [ $status ] in $(caller 0), calls [ ${BASH_LINENO[*]} ] command: \"$*\"" 1>&2
    fi

    return $status
}

#
# Function to illustrate important points in the build process
#
STEP_COUNT=0
function fxnPS()
{
    echo "Step: [ $STEP_COUNT ] $1"

    fxnPauseForUser

    STEP_COUNT=$(( STEP_COUNT +1 ))

}



function fxnHelp()
{
    # Set default configuration so values are visible in help
    fxnApplyDefaults
    echo ""
    echo " $0 [build|clean|run|qemu-hd-clean] --interactive"
    echo ""
    echo " Build and run the demonstration Secure Boot ONIE KVM and Demo OS"
    echo ""
    echo "Commands:"
    echo ""
    echo " Build commands:"
    echo "  clean               - Clean everything but the cross compile tools."
    echo "  build               - KVM build without Secure Boot."
    echo "  build-secure-boot   - Build signed grub, kernel, shim. Create second drive"
    echo "                          with signing keys for install in boot manager."
    echo "  build-shim          - Rebuild and sign the shim"
    echo "  build-uefi-vars     - generate kek-all.auth and db-all.auth"
	echo "  build-uefi-db-key <key> - Convert certifcate public key into uefi format to add to db."
    echo ""
    echo "  build-signed-only   - Only build components that need to be signed."
    echo "  --download-cache    - Use download cache in /var/cache/onie/download."
    echo "  --interactive         Build will pause between steps."
    echo "  --make-target       - build a makefile target with existing machine config variables."
    echo ""
    echo " Utility fuctions:"
    echo "  generate-keys <vendor > <name> <id> <comment>  Generate all the signing keys you'll need."
    echo "                         Vendor is $HW_VENDOR_PREFIX|$SW_VENDOR_PREFIX|$ONIE_VENDOR_PREFIX ..or something else"
    echo "                           to generate a full collection of keys."
    echo "                       Example: $0 generate-keys 'hw-vendor' 'ONIE-vendor' 'support@vendor.org' 'Vendor supplying ONIE' \"\$( date | tr ' ' '-')\" "
    echo "  generate-all-keys <date>  - Create hardware, software, and ONIE vendor keys."
    echo "                              if date is supplied it will be added to the organizationalUnitName in the certificate."
    echo "                        This is 'generate-keys' times 3 with defaults."
    echo "                        Keys end up under onie/encryption/keys/"
    echo "  generate-key-file <name> Create a CSV file that details where every key gets used. [ $DEFAULT_KEY_CONFIG_FILE]"
    echo "  --key-config-file <name> Use this CSV file rather than the default [ $DEFAULT_KEY_CONFIG_FILE]"
    echo ""
    echo " Informational commands:"
    echo "  info-check-signed   - What has(n't) been signed?"
    echo "  info-config         - What is getting configured?"
    echo ""
    echo " Options:"
    echo "  --machine-name   <name> Name of build target machine - ex mlnx_x86"
    echo "  --machine-revision  <r> The -rX version at the end of the --machine-name"
    echo "  --help                  This output."
    echo "  --help-examples         Examples of use."
    echo ""
    echo ""
    echo " Run this script from onie/build-config."
    echo ""
}

function fxnHelpExamples()
{
    local thisScript=$( basename $0 )
    echo "
 Help Examples
-----------------------------

# Building
# ---------------------------
# Build everything
    Cmd: $thisScript build
# Clean build (keep build tools)
    Cmd: $thisScript clean

"
}

function fxnPauseForUser()
{
    local userInput
    if [ "$DO_INTERACTIVE" = "TRUE" ];then
        echo "   Pausing. Press <Enter> to execute this ^^^ step."
        read userInput
        if [ "$userInput" = 'q' ];then
            echo "Exiting."
            exit
        else
            echo "   Continuing. Executing step [ $STEP_COUNT ]."
            echo ""
        fi
    fi
}

#
# Create a clean virtual hard drive to install on.
# Keep an unmodified backup copy for easy reversion.
#
function fxnCreateHardDrive ()
{
    if [ ! -e $HARD_DRIVE ];then
        fxnPS "Creating qcow2 image $HARD_DRIVE to use as 'hard drive'"
        qemu-img create -f qcow2 -o preallocation=full  $HARD_DRIVE ${HARD_DRIVE_SIZE}G || exit 1
        if [ -e "$CLEAN_HARD_DRIVE" ];then
            rm "$CLEAN_HARD_DRIVE"
        fi
    fi

    # Keep a copy of this that has not been installed on for debug purposes.
    if [ ! -e "$CLEAN_HARD_DRIVE" ];then
        echo "Creating untouched $HARD_DRIVE image at $CLEAN_HARD_DRIVE for reference."
        rsync --progress "$HARD_DRIVE" "$CLEAN_HARD_DRIVE"
    fi

}

#
# Populating a qcow2 image involves a loopback mount,
# which containers only support if they're run
# in --privileged mode,
# So this is a separate step in case it is being run
# OUTSIDE of the container, as root.
#
# Takes: if $1 = TRUE, delete existing drive and create fresh."
fxnUSBStoreFiles()
{
    local loop
    local deleteExistingDrive="$1"

    # If it has been built, then return.
    if [  -e $USB_IMG ];then
        if [ "$deleteExistingDrive" = "rebuild" ];then
            echo "Deleting existing virtual USB drive at [ $USB_IMG ] "
            rm $USB_IMG
        else
            fxnPS "$USB_IMG is present. Continuing."
            return 0
        fi
    fi

    echo "#####################################################"
    echo "#                                                   #"
    echo "# Building virtual USB drive /dev/vdb               #"
    echo "#                                                   #"
    echo "#####################################################"

    echo ""
    echo " Run as root "
    echo ""

    if [  -e /.dockerenv ]; then
        # In a container, then
        echo ""
        losetup --find
        if [ $? = 0 ];then
            echo "Found loopback in Docker container. Running --privileged. Continuing."
        else
            fxnWARN "Failed to find loopback devices in container."
            echo "The container was probably not run with host /dev mounted and '--privileged'."
            echo "You can run the creation of the USB filesystem image outside of container."
            return 1
        fi
    fi

    # At this point, running in a Docker container that mounts /dev,
    # or on a host where the user can sudo
    if [ ! -e /usr/bin/qemu-img ];then
        echo "/usr/bin/qemu-img not found. Installing..."
        sudo apt-get install qemu-utils || exit 1
    else
        echo "Found /usr/bin/qemu-img, continuing..."
    fi

    if [ ! -e $USB_MNT_DIR ];then
        echo "Creating mount point for loopback of USB file system."
        sudo mkdir -p $USB_MNT_DIR
    fi
    fxnPS "Creating '$USB_IMG'"
    qemu-img create -f raw ${USB_IMG}.raw "$USB_SIZE" || exit 1

    # And this would be the part one needs to be external for.
    # Try it in case the container is running --privileged
    loop=$( sudo /sbin/losetup  -f ${USB_IMG}.raw --show )
    if [ $? != 0 ];then
        echo "ERROR! Loopback mount of USB drive filesystem failed. (sudo /sbin/losetup  -f ${USB_IMG}.raw --show )"
        if [  -e /.dockerenv ]; then
            echo "Try virtual-usb outside of the container as root."
            echo ""
            exit 1
        fi
    fi
    echo " Accessing $USB_IMG raw filesystem via $loop"
    sudo mkdosfs -n "ONIE USB-DRIVE " $loop || exit 1
    if [ ! -e $USB_MNT_DIR ];then
        mkdir -p $USB_MNT_DIR || exit 1
    fi
    sudo mount $loop $USB_MNT_DIR || exit 1

    #
    # If changing keys around, make sure the USB drive is populated from
    # the usb transfer area
    fxnPopulateUSBTransfer

    #
    # Since loopback mounts will only work in a container if it has been
    # run with docker --privileged, having all the files copied into USB_XFER_DIR
    # as a staging area allows the this step to be run outside of a container as
    # well as inside one.
    #
    fxnPS "Secure: Copying over everything from $USB_XFER_DIR to $USB_MNT_DIR"

    # As this is a relative path, it should work in and out of the container.
    # Use rsync to skip copy of GPG sockets.
    fxnEC sudo rsync --recursive --no-specials --no-devices $USB_XFER_DIR/* $USB_MNT_DIR/ || exit 1

    if [ "$USB_SECURE_BOOT" = "TRUE" ];then
        if [ ! -e ${KEY_EFI_BINARIES_DIR}/UpdateVars.efi ];then
            echo "ERROR - UpdateVars.efi not found, so you can't apply these keys."
            exit 1
        fi
    fi

    if [ -e ../build/images/demo-installer-x86_64-${ONIE_MACHINE}.bin ];then
        sudo cp --verbose ../build/images/*installer-x86_64-${ONIE_MACHINE}*.bin  $USB_MNT_DIR/ || exit 1
    fi
    echo "============== USB Drive contains =========================="
    if [ "$USB_SECURE_BOOT" = "TRUE" ];then
        echo "== Hardware vendor keys:"
        ls -l "${USB_MNT_DIR}"/keys/${HW_VENDOR_PREFIX}
        echo ""
        echo "== Software vendor keys:"
        ls -l "${USB_MNT_DIR}"/keys/${SW_VENDOR_PREFIX}
        echo ""
        echo "== ONIE vendor keys:"
        ls -l "${USB_MNT_DIR}"/keys/${ONIE_VENDOR_PREFIX}
        echo ""
        echo "== Efi binaries:"
        ls -l "${USB_MNT_DIR}"/efi-binaries/*.efi
        echo ""
        echo "== Utilities:"
        #   ls -l "${USB_MNT_DIR}" | grep -v "${ONIE_VENDOR_PREFIX}\|${SW_VENDOR_PREFIX}\|${HW_VENDOR_PREFIX}\|.efi"
        ls -l "${USB_MNT_DIR}"/utilities/*
        echo ""
        echo "== demo images:"
        ls -l "${USB_MNT_DIR}"/demo*bin
        echo ""
        echo "== Top level directory "
        ls -l "${USB_MNT_DIR}"

        tree  "${USB_MNT_DIR}"
    else
        echo "== ${USB_MNT_DIR}"
        tree "${USB_MNT_DIR}"
    fi

    echo "============== End USB Drive contents ======================"
    # Install of external sbverify not guaranteed
    #   echo "  sbverify --no-verify $USB_MNT_DIR/kvm-images/${ONIE_MACHINE}.vmlinuz"
    #   sbverify --no-verify $USB_MNT_DIR/kvm-images/${ONIE_MACHINE}.vmlinuz || exit 1
    #   fxnPS "Confimred  $USB_MNT_DIR/kvm-images/${ONIE_MACHINE}.vmlinuz is signed."

    #TODO: consider making this an exit trap so we don't run out of loop devices,
    #      if debugging builds
    sudo umount $loop
    sudo /sbin/losetup -d $loop

    fxnPS "Secure: converting $USB_IMG format from .raw to .qcow2 in $KVM_DIR"
    qemu-img convert -f raw -O qcow2 ${USB_IMG}.raw ${USB_IMG}.qcow2 || exit 1
    echo ""
    fxnPS "Secure: Done creating 'usb drive'"
    ls -l "${KVM_DIR}"/*.qcow2

    echo " #"
    echo " # To continue:"
    echo " #  Use $0 --qemu-embed-onie --qemu-usb-drive "
    echo ""

}

#
# Clean out all staged keys and USB images as well
# as the kvm code
function fxnMakeClean()
{
    if [ $(basename $(pwd)) != "encryption" ];then
		echo "Must run from onie/encryption."
		exit 1
	fi
	echo "Doing encryption cleaning."
	rm -rf keys
	rm -rf machines
	return 0
		
    if [ $(basename $(pwd)) != "build-config" ];then
        echo "$0 must be run from onie/build-config. Exiting."
        exit 1
    fi

    echo "=== Cleaning Secure Boot artifiacts."

    if [ -e "${USB_XFER_DIR}" ];then
        echo "  Deleting      ${USB_XFER_DIR}"
        rm -rf "$USB_XFER_DIR"
    fi


    echo ""
    echo " Make clean with: $MACHINEROOT_DIR MACHINE=${ONIE_MACHINE_TARGET} clean "
    make $MACHINEROOT_DIR MACHINE=${ONIE_MACHINE_TARGET} clean

    echo ""
    echo "Done cleaning everything except the build tools and the safe place."

    if [ -e "$SAFE_PLACE" ];then
        echo ""
        echo " If you want to wipe the signed shim and keys, then:"
        echo "   rm -r $SAFE_PLACE"
        echo ""
        #        echo "  Deleting      $SAFE_PLACE"
        #        rm -rf $SAFE_PLACE
        # clean signed and unsigned shims
        #rm -rf "${SAFE_PLACE}/shim*efi*"
        #rm -rf "${SAFE_PLACE}/mm*efi*"
        #rm -rf "${SAFE_PLACE}/fb*efi*"

    fi

    echo "Removing existing shim."

    #    SHIM_PREBUILT_DIR=/home/adoyle/ONIE/vxDev/cleanRebuild/onie-cn/onie/safe-place#
    make "$MACHINEROOT_DIR" MACHINE="$ONIE_MACHINE_TARGET" V=1 clean
    exit

}

#
# Do the KVM build, and sign things.
#
function fxnBuildKVM()
{

    #
    # Since the "USB Drive" of addtional files gets created outside
    # the container, use this directory to hold all the files from
    # inside the container we'd like to see on that drive.
    #
    if [ ! -e "$USB_XFER_DIR" ];then
        echo "Secure: creating directories to hold 'usb drive' contents at: $USB_XFER_DIR"
        mkdir -p "$USB_XFER_DIR"     \
              "$USB_XFER_KEY_DIR"          \
              "$USB_XFER_HW_KEY_DIR"       \
              "$USB_XFER_SW_KEY_DIR"       \
              "$USB_XFER_ONIE_KEY_DIR"     \
              "$KEY_EFI_BINARIES_DIR" \
              "$KEY_UTILITIES_DIR"   || exit 1
    else
        echo " $USB_XFER_DIR exists"
    fi
    echo "USB transfer drive directory contains."
    tree "$USB_XFER_DIR"

    if [ "$BUILD_SECURE_BOOT" != "TRUE" ];then
        echo "     time make SECURE_BOOT_ENABLE=no $MACHINEROOT_DIR MACHINE=${ONIE_MACHINE_TARGET} -j8 all demo recovery-iso "
        time fxnEC make $DOWNLOAD_CACHE SECURE_BOOT_ENABLE=no $MACHINEROOT_DIR MACHINE=${ONIE_MACHINE_TARGET} -j8 all demo recovery-iso || exit 1
    else
        # Sourced from kvm-secure.lib
        # Where MAKE_TARGET is 'all' or 'grub', etc.
        fxnBuildSecure "$MAKE_TARGET"

    fi
    #    fxnPS "Starting by building unsigned kvm target:"
    #    time make V=1 -j8 ${MACHINE_BUILD_TARGET} all demo recovery-iso  > secure-1-build-unsigned-kvm.log 2>&1 || exit 1


    if [ ! -e $KVM_DIR ];then
        echo "Secure: creating $KVM_DIR to store KVM files in."
        mkdir -p $KVM_DIR
    else
        echo "$KVM_DIR exists."
    fi

    #
    # Use copies of the system's local install of ovmf for UEFI emulation
    #
    if [ ! -e "${KVM_DIR}/OVMF.fd" ];then
        fxnPS "NOT Secure: USB-DRIVE: Copying unmodified $UEFI_BIOS_SOURCE from the ovmf package: to ${KVM_DIR}/"
        cp "$UEFI_BIOS_SOURCE"  ${KVM_DIR}/ || exit 1
    else
        fxnPS "UEFI BIOS from OVMF.fd already exists in ${KVM_DIR}/"
    fi

    if [ ! -e "${KVM_DIR}/OVMF_CODE.fd" ];then
        fxnPS "NOT Secure: USB-DRIVE: Copying unmodified $UEFI_BIOS_SOURCE_CODE from the ovmf package: to ${KVM_DIR}/"
        cp "$UEFI_BIOS_SOURCE_CODE"  ${KVM_DIR}/ || exit 1
    else
        fxnPS "UEFI BIOS code file from OVMF_CODE.fd already exists in ${KVM_DIR}/"
    fi

    if [ ! -e "${KVM_DIR}/OVMF_VARS.fd" ];then
        fxnPS "NOT Secure: USB-DRIVE: Copying unmodified $UEFI_BIOS_SOURCE_VARS from the ovmf package: to ${KVM_DIR}/"
        cp "$UEFI_BIOS_SOURCE_VARS"  ${KVM_DIR}/ || exit 1
    else
        fxnPS "UEFI BIOS variable storage file from OVMF_VARS.fd already exists in ${KVM_DIR}/"
    fi


    fxnPS "Copying build products from ${BUILD_DIR}/images/*${ONIE_MACHINE_TARGET}* to: ${KVM_DIR}/"

    cp ${BUILD_DIR}/images/*${ONIE_MACHINE_TARGET}* ${KVM_DIR}/|| exit 1

    # Create a target filesystem for install and a backup copy.
    fxnCreateHardDrive

    echo " $KVM_DIR contents"
    ls -l ${KVM_DIR}

    #
    # create a USB image to have all the files stuffed into USB_XFER_DIR
    #
    #
    if [ "$DO_QEMU_USB_DRIVE" = "TRUE" ];then
        if [ ! -e $USB_IMG ];then
            fxnUSBStoreFiles
        else
            fxnPS "Secure: $USB_IMG is present. Continuing."
        fi
    fi

}


# One stop to set default values for the run.
function fxnApplyDefaults()
{
    # KVM defaults
    #    ONIE_KERNEL_VERSION="linux-4.19.143"
    #ONIE_MACHINE_TARGET="cumulus_vx"
	ONIE_MACHINE_TARGET="kvm_x86_64"	
    #     MACHINEROOT_DIR="MACHINEROOT=../machine/cumulus"
    #    MACHINEROOT_DIR=""
    DO_INTERACTIVE="FALSE"
    # Just edit these in place
    if [ "$APPLY_HARDCODE_DEFAULTS" = "TRUE" ];then
        echo ""
        echo "NOTE: Applying QEMU/ONIE hardcode default settings."
        echo ""
        MACHINE_REVISION="-r0"
        ONIE_MACHINE_REVISION="-r0"
    fi

    # And the values that get set from the above
    ONIE_MACHINE="${ONIE_MACHINE_TARGET}${ONIE_MACHINE_REVISION}"
    ONIE_KERNEL="../build/${ONIE_MACHINE}/kernel/${ONIE_KERNEL_VERSION}/arch/x86_64/boot/bzImage"
    ONIE_INITRD="../build/images/${ONIE_MACHINE}.initrd"
    ONIE_VMLINUX="../build/${ONIE_MACHINE}/kernel/${ONIE_KERNEL_VERSION}/vmlinux"
    ONIE_RECOVERY_ISO="../build/images/onie-recovery-x86_64-${ONIE_MACHINE}.iso"
    ONIE_DEMO_INSTALLER="../build/images/demo-installer-x86_64-${ONIE_MACHINE}.bin"

}

# Spell out what has been set
function fxnPrintSettings()
{
    echo ""
    echo "####################################################"
    echo "#"
    echo "#  $0 Settings "
    echo "#"
    echo "#--------------------------------------------------"
    echo "#  Running in         [ $(pwd) ]"
    echo "#  Machine name       [ $ONIE_MACHINE_TARGET ] "
    echo "#  Machine revision   [ $MACHINE_REVISION ]"
    echo "#  Interactive        [ $DO_INTERACTIVE ]"
    echo "#  Boot from CD       [ $DO_BOOT_FROM_CD ]"
    echo "#"
    if [ -e "$ONIE_KERNEL" ];then
        echo "#  ONIE Kernel        [ $ONIE_KERNEL_VERSION ]"
    fi
    echo "#  ONIE machine tgt   [ $ONIE_MACHINE_TARGET ]"
    echo "#  ONIE machine rev   [ $ONIE_MACHINE_REVISION ]"
    if [ "$BUILD_SECURE_BOOT" = "TRUE" ];then
        fxnPrintSecureBootSettings
    fi
    echo "####################################################"
    echo ""
}


##################################################
#                                                #
# MAIN  - script processing starts here          #
#                                                #
##################################################

if [ "$#" = "0" ];then
    # Require an argument for action.
    # Always trigger help messages on no action.
    fxnHelp
    exit 0
fi

# Set a default configuration that the CLI can override.
fxnApplyDefaults

#
# Gather arguments and set action flags for processing after
# all parsing is done. The only functions that should get called
# from here are ones that take no arguments.
while [[ $# -gt 0 ]]
do
    term="$1"

    case $term in
        # Build for a standard ONIE simulation - rescue iso and kvm
        clean )
            DO_CLEAN="TRUE"
            ;;

		clobber )
			DO_CLOBBER="TRUE"
			;;
		
        # rebuild the ONIE target
        build )
            DO_BUILD="TRUE"
            ;;

        # Generate signing keys
        generate-keys )
            if [ "$5" = "" ];then
                echo "Supply a vendor, type name, user email,  and a description to  associate with the cerficiate."
                echo "  Ex: $0 generate-keys 'hw-vendor' 'ONIE-vendor' 'support@vendor.org' 'Vendor supplying ONIE' 'optional date'"
                echo " Exiting."
                echo ""
                exit 1
            fi
            fxnGenerateKeys "$2" "$3" "$4" "$5" "$6"
            exit
            ;;

        # Generate test keys for a hardware vendor, software vendor, and ONIE vendor.
        # If $2 is set, add it to the organizationalUnit name in the certificate
        generate-all-keys )
            fxnGenerateAllKeys $2
            exit
            ;;

        --key-config-file )
            # pass in csv file holding key locations
            KEY_CONFIG_FILE="$2"
            shift
            ;;

        generate-key-file )
            # Generate a csv file to use
            fxnGenerateCSVKeyFile "$2"
            exit
            ;;

		read-key-file )
			fxnReadKeyConfigFile
			echo "$ALL_SIGNING_KEYS"
			exit
			;;
		
        --interactive )
            DO_INTERACTIVE="TRUE"
            ;;

        # Build a particular target with existing machine prefixes.
        --make-target )
            MAKE_TARGET="$2"
            shift
            ;;

        --download-cache )
            DOWNLOAD_CACHE=" ONIE_USE_SYSTEM_DOWNLOAD_CACHE=TRUE "
            ;;


        --machine-name )
            if [ "$2" = "" ];then
                echo "ERROR! Must supply a machine name: ex 'mlnx_x86'. Exiting."
                exit 1
            fi
            ONIE_MACHINE_TARGET="$2"
            shift
            ;;
        --machine-revision )
            if [ "$2" = "" ];then
                echo "ERROR! Must supply a machine revision: ex '-r0'. Exiting."
                exit 1
            fi
            ONIE_MACHINE_REVISION="$2"
            shift
            ;;

        build-secure-boot )
            # Build the ONIE target
            DO_BUILD="TRUE"
            # Got through signing everything.
            BUILD_SECURE_BOOT="TRUE"
            # A virtual USB drive should expect to have secure boot files
            USB_SECURE_BOOT="TRUE"
            # Create a second filesystem to store keys that must be loaded
            # in to the bios, and have that present as a USB drive.
            DO_QEMU_USB_DRIVE="TRUE"
            ;;

        build-signed-only )
            # Only rebuild components that need to be signed.
            DO_BUILD_SIGNED_ONLY="TRUE"
            ;;

        build-shim )
            # test build the shim
            DO_BUILD_SHIM_ONLY="TRUE"
            ;;

        build-uefi-vars )
            # Build UEFI database variables
            DO_BUILD_UEFI_VARS="TRUE"
            ;;

		build-uefi-db-key )
			fxnAddUEFIDBKey "$2"
			exit
			;;
		
        info-check-signed )
            # Check all things that could be signed
            fxnVerifySigned
            exit 0
            ;;

        info-config )
            # Print out any configuration information
            fxnPrintSecureBootSettings
            exit 0
            ;;


        --help )
            fxnHelp
            exit 0
            ;;


        --help-examples )
            fxnHelpExamples
            exit 0
            ;;

        *)
            fxnHelp
            echo "Unrecognized option [ $term ]. Exiting"
            exit 1
            ;;

    esac
    shift # skip over argument

done


if [ "$DO_CLEAN" = "TRUE" ];then
    fxnMakeClean
	exit 
fi

# Hardcore cleaning
if [ "$DO_CLOBBER" = "TRUE" ];then
	fxnMakeClean
	rm -rf safe-place/*
	rm -rf ../emulation/emulation-files/usb/usb-data/*
	cd ../build-config
	make clean
	
fi

# Always read a file if it exists, create and use defaults if it doesn't
fxnReadKeyConfigFile


if [ "$DO_BUILD_UEFI_VARS" = "TRUE" ];then
    fxnGenerateKEKAndDBEFIVars
fi
# Copy and use OVMF_VARS file here
# Handy to test different pre-configured BIOS settings
# Different hardware/owner keys, for example.
if [ "$USE_OVMF_VARS_FILE" != "" ];then
    echo "Using saved OVMF_VARS file."
    echo "  Deleting old ${KVM_DIR}/OVMF_VARS.fd"
    rm "${KVM_DIR}/OVMF_VARS.fd"
    echo "  Replacing with:  [ $USE_OVMF_VARS_FILE ]"
    cp "$USE_OVMF_VARS_FILE" "${KVM_DIR}/OVMF_VARS.fd"
fi


if [ "$DO_BUILD_SHIM_ONLY" = "TRUE" ];then
    fxnRebuildSHIM
    exit
fi

# Just rebuild components that need to be signed.
# Useful when debugging key configurations.
if [ "$DO_BUILD_SIGNED_ONLY" = "TRUE" ];then
    fxnBuildSignedOnly
    exit
fi


if [ "$DO_BUILD" = "TRUE" ];then
    if [ -e /.dockerenv ];then
        fxnBuildKVM
    else
        echo "Error: Trying to build outside a DUE container."
        exit 1
    fi
fi

