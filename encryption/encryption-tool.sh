#!/bin/bash
#-------------------------------------------------------------------------------
#
#  Copyright (C) 2021 Alex Doyle <adoyle@nvidia.com>
#
#-------------------------------------------------------------------------------

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

ENCRYPTION_DIR="${ONIE_TOP_DIR}/encryption"

if [ "$1" = "--debug" ];then
    echo "Enabling top level --debug"
    # and we'll hide that argument
    shift
    set -x
fi

ONIE_MACHINE_TARGET="kvm_x86_64"
# path to manfuacturer, if any
MANUFACTURER_DIR=""
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
    echo "  update-keys           Have code recognize new key locations. Updates makefile fragment."
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
# Clean out all staged keys and USB images as well
# as the kvm code
function fxnMakeClean()
{
    local keyPathsDir="${ENCRYPTION_DIR}/machines/${ONIE_MACHINE_TARGET}"
    local keyPathsFile="${keyPathsDir}/signing-key-paths.make"
    if [ $(basename $(pwd)) != "encryption" ];then
        echo "Must run from ${ENCRYPTION_DIR}."
        exit 1
    fi
    echo "Doing encryption cleaning."
    echo "  Deleting keys directory"
    rm -rf keys

    echo "=== Cleaning Secure Boot artifiacts."

    if [ -e "${USB_XFER_DIR}" ];then
        echo "  Deleting      ${USB_XFER_DIR}"
        rm -rf "$USB_XFER_DIR"
    fi

    # If necessary, create a dummy key path file so the make clean won't fail to find it.
    if [ ! -e "$keyPathsFile" ];then
        mkdir -p "$keyPathsDir"
        touch "$keyPathsFile"
    fi

    cd ../build-config
    echo ""


    echo " Make clean with: $MANUFACTURER_DIR MACHINE=${ONIE_MACHINE_TARGET} clean "
    if [ "$MANUFACTURER_DIR" = "" ];then
        # Targets like kvm_x86_64 may not have a manfuacturer directory
        make  MACHINE="$ONIE_MACHINE_TARGET"  clean
    else
        make "$MANUFACTURER_DIR" MACHINE="$ONIE_MACHINE_TARGET"  clean
    fi

    cd "${ENCRYPTION_DIR}"

    # Delete this last, as it has the signing-key-paths.make file, and the
    # make clean will fail if that is missing
    echo "  Deleting machines directory."
    rm -rf machines

    echo "Done clean"
}



# One stop to set default values for the run.
function fxnApplyDefaults()
{
    # KVM defaults
    #    ONIE_KERNEL_VERSION="linux-4.19.143"
    #ONIE_MACHINE_TARGET="cumulus_vx"
    ONIE_MACHINE_TARGET="kvm_x86_64"

    # Set for targets that have a manufacturer in their path
    #ONIE_MACHINE_MANUFACTURER
    #     MANUFACTURER_DIR="MACHINEROOT=../machine/cumulus"
    #    MANUFACTURER_DIR=""
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
    # If extended secure boot is active for this machine, case then note it

    grep -v '#' ../machine/${ONIE_MACHINE_MANUFACTURER}/${ONIE_MACHINE_TARGET}/machine.make | grep -q "SECURE_BOOT_EXT "
    if [ $? = 0 ];then
        ONIE_SECURE_BOOT_EXTENDED="TRUE"
    else
        ONIE_SECURE_BOOT_EXTENDED="FALSE"
    fi

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

        update-keys )
            # read keys from the csv file and update where needed.
            fxnUpdateKeyData
            exit
            ;;

        --interactive )
            DO_INTERACTIVE="TRUE"
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

        build-uefi-vars )
            # Build UEFI database variables
            DO_BUILD_UEFI_VARS="TRUE"
            ;;

        build-uefi-db-key )
            fxnAddUEFIDBKey "$2"
            exit
            ;;

        info-check-signed | audit )
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
    echo "Deleting safe-place/*efi*"
    rm -rf safe-place/*efi*
    rm -rf ../emulation/emulation-files/usb/usb-data/*
    exit
fi

# Always read a file if it exists, create and use defaults if it doesn't
fxnReadKeyConfigFile


if [ "$DO_BUILD_UEFI_VARS" = "TRUE" ];then
    fxnGenerateKEKAndDBEFIVars
fi

