#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Script to indeitify the hardware we are running on

if [[ -z ${GUARD_QN_ID_SH} ]]; then
  GUARD_QN_ID_SH=1
else
  return
fi

# Identify the hardware by a string
#
# Parameters:
#   $1[out]: The hardware string
# Returns:
#   0: Success
#   1: Failure
id_identify() {
  # NOTE: To help future devs who don't have access to your hardware,
  # please provide the output of the following commnands in comments:
  # 
  # dmidecode -t 0,1,2,3,4
  local _name="$1"
  local res=1
  
  # Try to identify the motherboard via DMI
  local table2
  local product_name
  local manufacturer
  
  table2=$(dmidecode -t 2)
  if [[ -z "${table2}" ]]; then
    logError "Failed to get DMI table 2"
    return 1
  fi

  manufacturer=$(echo "${table2}" | grep "Manufacturer" | awk -F': ' '{print $2}')
  product_name=$(echo "${table2}" | grep "Product Name" | awk -F': ' '{print $2}')
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

        eval "${_name}='QNAP TVS-663'"
        logInfo "Recognized the motherboard used in a QNAP TVS-663: ${product_name}"
        res=0
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

  return ${res}
}



###########################
###### Startup logic ######
###########################

ID_ARGS=("$@")
ID_CWD=$(pwd)
ID_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
ID_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${ID_SOURCE}" ]]; do # resolve $ID_SOURCE until the file is no longer a symlink
  ID_ROOT=$(cd -P "$(dirname "${ID_SOURCE}")" >/dev/null 2>&1 && pwd)
  ID_SOURCE=$(readlink "${ID_SOURCE}")
  [[ ${ID_SOURCE} != /* ]] && ID_SOURCE=${ID_ROOT}/${ID_SOURCE} # if $ID_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
ID_ROOT=$(cd -P "$(dirname "${ID_SOURCE}")" >/dev/null 2>&1 && pwd)
ID_ROOT=$(realpath "${ID_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${ID_ROOT}/external/setup"
source ${SETUP_REPO_DIR}/src/slf4sh.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  if id_identify result; then
    echo "${result}"
  else
    exit 1
  fi
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  if id_identify result; then
    echo "${result}"
  else
    exit 1
  fi
fi
