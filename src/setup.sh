#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script is used to configure the qnap machine
#
# Currently tested on XCP-ng 8.3 (CentOS)

AGE_KEY="homeinfra_demers"

setup() {
  declare -g DQ_ARGS=("$@")
  logInfo "Setup called with: ${DQ_ARGS[@]}"

  # Make sure we are running on the right system
  if ! check_system; then
    logError "This script is not supported on this system"
    return 1
  fi

  # Make sure git is installed and configured
  if ! git_install; then
    logInfo "Failed to install git"
    return 1
  fi
  if ! git_configure "${DQ_ROOT}"; then
    logInfo "Failed to configure git"
    return 1
  fi

  # Install and configure configuration cyphering
  if ! sops_install; then
    logInfo "Failed to install sops"
    return 1
  fi
  if ! age_install; then
    logInfo "Failed to install age"
    return 1
  fi
  if ! age_configure "${AGE_KEY}"; then
    logInfo "Failed to configure age"
    return 1
  fi

  config_load "${DQ_ROOT}/data/qnap.env"

  # Install drivers for the 10 GBe NIC
  if ! aq113c_install; then
    logInfo "Failed to install AQ113C drivers"
    return 1
  fi

  if ! validate_hardware; then
    logError "Failed to validate hardware"
    return 1
  fi

  return 0
}

# Validate hardware
validate_hardware() {
  # Validate network interfaces
  local macs=()
  local nw_validate_nic
  for nic in ${NICS}; do
    nic="${nic}_MAC"
    if [[ -n "${!nic}" ]]; then
      macs+=("${!nic}")
    else
      logError "Variable ${nic} is not set or empty"
      return 1
    fi
  done

  if nw_validate_nic "${macs[@]}"; then
    logInfo "All network interfaces exist"
  else
    logError "At least one NIC is invalid"
    return 1
  fi

  return 0
}

# NOTE: To help future devs who don't have access to your hardware,
# please provide the output of the following commnands in comments:
# 
# dmidecode -t 0,1,2,3,4
check_system() {
  # Try to identify the motherboard
  local table2
  local product_name
  local manufacturer
  
  table=$(dmidecode -t 2)
  if [[ -z "${table}" ]]; then
    logError "Failed to get DMI table 2"
    return 1
  fi

  manufacturer=$(echo "${table}" | grep "Manufacturer" | awk -F': ' '{print $2}')
  product_name=$(echo "${table}" | grep "Product Name" | awk -F': ' '{print $2}')
  if [[ -z "${manufacturer}" ]] || [[ -z "${product_name}" ]]; then
    logError "Failed to get motherboard identification"
    return 1
  fi
  case "${manufacturer}" in
    "iEi")
      logInfo "Detected a board made by IEI Integration Corp."
      case "${product_name}" in
      "E452")
        # Handle 0x0000, DMI type 0, 24 bytes
        # BIOS Information
        #         Vendor: American Megatrends Inc.
        #         Version: E452AR18
        #         Release Date: 05/16/2017
        #         Address: 0xF0000
        #         Runtime Size: 64 kB
        #         ROM Size: 1024 kB
        #         Characteristics:
        #                 PCI is supported
        #                 BIOS is upgradeable
        #                 BIOS shadowing is allowed
        #                 Boot from CD is supported
        #                 Selectable boot is supported
        #                 BIOS ROM is socketed
        #                 EDD is supported
        #                 5.25"/1.2 MB floppy services are supported (int 13h)
        #                 3.5"/720 kB floppy services are supported (int 13h)
        #                 3.5"/2.88 MB floppy services are supported (int 13h)
        #                 Print screen service is supported (int 5h)
        #                 8042 keyboard services are supported (int 9h)
        #                 Serial services are supported (int 14h)
        #                 Printer services are supported (int 17h)
        #                 ACPI is supported
        #                 USB legacy is supported
        #                 BIOS boot specification is supported
        #                 Targeted content distribution is supported
        #                 UEFI is supported
        #         BIOS Revision: 4.6
        #
        # Handle 0x0001, DMI type 1, 27 bytes
        # System Information
        #         Manufacturer: iEi
        #         Product Name: E452
        #         Version: V1.00
        #         Serial Number: To be filled by O.E.M.
        #         UUID: 03000200-0400-0500-0006-000700080009
        #         Wake-up Type: Power Switch
        #         SKU Number: To be filled by O.E.M.
        #         Family: To be filled by O.E.M.
        # 
        # Handle 0x0002, DMI type 2, 15 bytes
        # Base Board Information
        #         Manufacturer: iEi
        #         Product Name: E452
        #         Version: V1.00
        #         Serial Number: To be filled by O.E.M.
        #         Asset Tag: To be filled by O.E.M.
        #         Features:
        #                 Board is a hosting board
        #                 Board is replaceable
        #         Location In Chassis: To be filled by O.E.M.
        #         Chassis Handle: 0x0003
        #         Type: Motherboard
        #         Contained Object Handles: 0
        #
        # Handle 0x0003, DMI type 3, 25 bytes
        # Chassis Information
        #         Manufacturer: To Be Filled By O.E.M.
        #         Type: Desktop
        #         Lock: Not Present
        #         Version: To Be Filled By O.E.M.
        #         Serial Number: To Be Filled By O.E.M.
        #         Asset Tag: To Be Filled By O.E.M.
        #         Boot-up State: Safe
        #         Power Supply State: Safe
        #         Thermal State: Safe
        #         Security Status: None
        #         OEM Information: 0x00000000
        #         Height: Unspecified
        #         Number Of Power Cords: 1
        #         Contained Elements: 1
        #                 <OUT OF SPEC> (0)
        #         SKU Number: To be filled by O.E.M.
        #
        # Handle 0x001A, DMI type 4, 42 bytes
        # Processor Information
        #         Socket Designation: P0
        #         Type: Central Processor
        #         Family: G-Series
        #         Manufacturer: AuthenticAMD
        #         ID: FF FB 8B 17 01 0F 73 00
        #         Signature: Family 11, Model 15, Stepping 15
        #         Flags:
        #                 FPU (Floating-point unit on-chip)
        #                 CX8 (CMPXCHG8 instruction supported)
        #                 APIC (On-chip APIC hardware supported)
        #                 SEP (Fast system call)
        #                 PAT (Page attribute table)
        #                 PSE-36 (36-bit page size extension)
        #                 DS (Debug store)
        #                 ACPI (ACPI supported)
        #         Version: AMD GX-424CC SOC with Radeon(TM) R5E Graphics
        #         Voltage: 1.4 V
        #         External Clock: 100 MHz
        #         Max Speed: 2400 MHz
        #         Current Speed: 2400 MHz
        #         Status: Populated, Enabled
        #         Upgrade: None
        #         L1 Cache Handle: 0x0018
        #         L2 Cache Handle: 0x0019
        #         L3 Cache Handle: Not Provided
        #         Serial Number: Not Specified
        #         Asset Tag: Not Specified
        #         Part Number: Not Specified
        #         Core Count: 4
        #         Core Enabled: 4
        #         Thread Count: 4
        #         Characteristics:
        #                 64-bit capable

        logInfo "Recognized the motherboard used in a QNAP TVS-x63"
        return 0
        ;;
      *)
        logError "Motherboard is not recognized: ${product_name}"
        ;;
      esac
      ;;
    *)
      logError "Manufacturer is not recognized: ${manufacturer}"
      ;;
  esac

  return 1
}

###########################
###### Startup logic ######
###########################

DQ_ARGS=("$@")
DQ_CWD=$(pwd)
DQ_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
DQ_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${DQ_SOURCE}" ]]; do # resolve $DQ_SOURCE until the file is no longer a symlink
  DQ_ROOT=$(cd -P "$(dirname "${DQ_SOURCE}")" >/dev/null 2>&1 && pwd)
  DQ_SOURCE=$(readlink "${DQ_SOURCE}")
  [[ ${DQ_SOURCE} != /* ]] && DQ_SOURCE=${DQ_ROOT}/${DQ_SOURCE} # if $DQ_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DQ_ROOT=$(cd -P "$(dirname "${DQ_SOURCE}")" >/dev/null 2>&1 && pwd)
DQ_ROOT=$(realpath "${DQ_ROOT}/..")

# Import dependencies
source ${DQ_ROOT}/external/setup/src/slf4sh.sh
source ${DQ_ROOT}/external/setup/src/git.sh
source ${DQ_ROOT}/external/setup/src/sops.sh
source ${DQ_ROOT}/external/setup/src/age.sh
source ${DQ_ROOT}/external/setup/src/config.sh
source ${DQ_ROOT}/src/aq113c/aq113c.sh
source ${DQ_ROOT}/libs/xenapi/src/network.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  setup "${@}"
  exit $?
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  echo "ERROR: This script cannot be sourced"
  exit 1
else
  # This script was executed
  setup "${@}"
  exit $?
fi
