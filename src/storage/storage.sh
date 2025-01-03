# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script configures the persistent storage for the XCP-ng host

if [[ -z ${GUARD_STORAGE_SH} ]]; then
  GUARD_STORAGE_SH=1
else
  return 0
fi

storage_setup() {
  STOR_FILE="${CONFIG_DIR}/storage.env"

  local res=0
  while [[ ${res} -eq 0 ]]; do
    # Load the new configuration
    config_load "${STOR_FILE}"

    if [[ -z ${STOR_STATE} ]]; then
      storage_design
      res=$?
    else
      case ${STOR_STATE} in
      designed)
        storage_create
        res=$?
        ;;
      created)
        storage_mount
        res=$?
        ;;
      mounted)
        if [[ ${res} -eq 0 ]]; then
          logInfo "Storage configured succesfully"
        else
          logError "Failed to mount storage"
        fi
        break
        ;;
      *)
        logError "Unknown state: ${STOR_STATE}"
        return 1
        ;;
      esac
    fi
  done

  # shellcheck disable=SC2248
  return ${res}
}

storage_mount() {
  STOR_FILE="${CONFIG_DIR}/storage.env"
  if ! config_load "${STOR_FILE}"; then
    logError "Failed to load storage configuration"
    return 1
  fi

  # Validate current state
  case ${STOR_STATE} in
  created)
    :
    ;;
  mounted)
    logInfo "Storage already mounted"
    return 0
    ;;
  *)
    logError "Invalid state for storage: ${STOR_STATE}"
    return 1
    ;;
  esac

  # First: VM Storage
  if [[ ${VM_STOR_DRIVE1_START} -ne 0 ]] || [[ ${VM_STOR_DRIVE2_START} -le 0 ]] || [[ ${VM_STOR_SIZE} -le 0 ]]; then
    logError "Invalid configuration for VM storage: ${VM_STOR_DRIVE1_START} ${VM_STOR_DRIVE2_START} ${VM_STOR_SIZE}"
    return 1
  fi

  # Only support the case where DISK2 isn't at the beggining of the drive. We need to mount a loop device for it
  local vm_loop_device
  if ! disk_create_loop vm_loop_device "${VM_STOR_DRIVE2}" "${VM_STOR_DRIVE2_START}" "${VM_STOR_SIZE}"; then
    logError "Failed to create loop device for VM storage"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_LOOP2 "${vm_loop_device}"; then
    logError "Failed to save VM_STOR_LOOP2"
    return 1
  elif ! disk_assemble_radi1 "${VM_STOR_DRIVE}" "${VM_STOR_DRIVE1}" "${vm_loop_device}"; then
    logError "Failed to assemble RAID 1 array for VM storage"
    return 1
  elif ! xe_stor_plug "${VM_STOR_NAME}"; then
    logError "Failed to plug VM storage"
    return 1
  else
    logInfo "VM storage connected"
  fi

  # Second: ISO Storage
  if [[ ${ISO_STOR_START} -le 0 ]] || [[ ${ISO_STOR_SIZE} -le 0 ]]; then
    logError "Invalid configuration for ISO storage: ${ISO_STOR_START} ${ISO_STOR_SIZE}"
    return 1
  fi

  # Only support the case where storage isn't at the beginning of the drive. We need to mount a loop device for it
  local iso_loop_device
  if ! disk_create_loop iso_loop_device "${ISO_STOR_DRIVE}" "${ISO_STOR_START}" "${ISO_STOR_SIZE}"; then
    logError "Failed to create loop device for ISO storage"
    return 1
  elif ! config_save "${STOR_FILE}" "ISO_STOR_LOOP" "${iso_loop_device}"; then
    logError "Failed to save ISO_STOR_LOOP"
    return 1
  elif ! mount "/dev/${iso_loop_device}" "${ISO_STOR_PATH}"; then
    logError "Failed to mount ISO storage"
    return 1
  elif ! xe_stor_plug "${ISO_STOR_NAME}"; then
    logError "Failed to plug ISO storage"
    return 1
  else
    logInfo "ISO Storage connected"
  fi

  # Save the configuration as mounted
  if ! config_save "${STOR_FILE}" STOR_STATE mounted; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage mounted"
  fi

  return 0
}

storage_unmount() {
  STOR_FILE="${CONFIG_DIR}/storage.env"
  if ! config_load "${STOR_FILE}"; then
    logError "Failed to load storage configuration"
    return 1
  fi

  # Validate current state
  case ${STOR_STATE} in
  mounted)
    :
    ;;
  created)
    logInfo "Storage already unmounted"
    return 0
    ;;
  *)
    logError "Invalid state for storage: ${STOR_STATE}"
    return 1
    ;;
  esac

  # First: ISO Storage
  if ! xe_stor_unplug "${ISO_STOR_NAME}"; then
    logError "Failed to unplug ISO storage"
    return 1
  elif ! umount "${ISO_STOR_PATH}"; then
    logError "Failed to unmount ISO storage"
    return 1
  elif [[ -z ${ISO_STOR_LOOP} ]]; then
    logError "Missing loop device for ISO storage"
    return 1
  elif ! disk_remove_loop "${ISO_STOR_LOOP}"; then
    logError "Failed to remove loop device for ISO storage"
    return 1
  elif ! config_save "${STOR_FILE}" ISO_STOR_LOOP ""; then
    logError "Failed to remove ISO_STOR_LOOP"
    return 1
  else
    logInfo "ISO storage disconnected"
  fi

  # Second: VM Storage
  if ! xe_stor_unplug "${VM_STOR_NAME}"; then
    logError "Failed to unplug VM storage"
    return 1
  elif ! disk_remove_raid "${VM_STOR_DRIVE}"; then
    logError "Failed to remove RAID array for VM storage"
    return 1
  elif [[ -z ${VM_STOR_LOOP2} ]]; then
    logError "Missing loop device for VM storage"
    return 1
  elif ! disk_remove_loop "${VM_STOR_LOOP2}"; then
    logError "Failed to remove loop device for VM storage"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_LOOP2 ""; then
    logError "Failed to remove VM_STOR_LOOP2"
    return 1
  else
    logInfo "RAID array removed for VM storage"
  fi

  # Save the configuration as created
  if ! config_save "${STOR_FILE}" STOR_STATE created; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage unmounted"
  fi

  return 0
}

storage_create() {
  if [[ -z ${VM_STOR_DRIVE1} ]] || [[ -z ${VM_STOR_DRIVE2} ]] || [[ -z ${VM_STOR_DRIVE1_START} ]] || [[ -z ${VM_STOR_DRIVE2_START} ]] || [[ -z ${VM_STOR_SIZE} ]]; then
    logError "Missing configuration for VM storage"
    return 1
  fi
  if [[ "${VM_STOR_DRIVE1}" == "${VM_STOR_DRIVE2}" ]]; then
    logError "VM storage drives are the same"
    return 1
  fi
  if [[ ${VM_STOR_DRIVE1_START} -ne 0 ]] || [[ ${VM_STOR_DRIVE2_START} -le 0 ]] || [[ ${VM_STOR_SIZE} -le 0 ]]; then
    logError "Invalid configuration for VM storage"
    return 1
  fi
  if [[ -z ${ISO_STOR_DRIVE} ]] || [[ -z ${ISO_STOR_START} ]] || [[ -z ${ISO_STOR_SIZE} ]]; then
    logError "Missing configuration for ISO storage"
    return 1
  fi

  local vm_loop_device
  local iso_loop_device
  local res=0

  # If we reach here, we've confirmed the need to create a loop device for drive 2
  if ! disk_create_loop vm_loop_device "${VM_STOR_DRIVE2}" "${VM_STOR_DRIVE2_START}" "${VM_STOR_SIZE}"; then
    logError "Failed to create loop device for VM storage"
    return 1
  else
    logInfo "Loop device created for VM storage: ${vm_loop_device}"
  fi

  # Create the RAID1 array
  if ! disk_create_raid1 "${VM_STOR_DRIVE}" "${VM_STOR_DRIVE1}" "${vm_loop_device}"; then
    logError "Failed to create RAID1 array for VM storage"
    return 1
  else
    logInfo "RAID1 array created for VM storage"
  fi

  # Create the SR record for the VM storage
  if ! xe_stor_create_lvm res "${VM_STOR_NAME}" "${VM_STOR_DRIVE}"; then
    logError "Failed to create SR record for VM storage"
    return 1
  else
    logInfo "SR record created for VM storage: ${res}"
  fi

  # Create the ISO storage
  if ! disk_create_loop iso_loop_device "${ISO_STOR_DRIVE}" "${ISO_STOR_START}" "${ISO_STOR_SIZE}"; then
    logError "Failed to create loop device for ISO storage"
    return 1
  else
    logInfo "Loop device created for ISO storage: ${iso_loop_device}"
  fi

  # Format the ISO storage
  if ! disk_format "${iso_loop_device}" "ext4"; then
    logError "Failed to format ISO storage"
    return 1
  else
    logInfo "ISO storage formatted"
  fi

  # Mount the ISO storage
  if ! mkdir -p "${ISO_STOR_PATH}"; then
    logError "Failed to create ISO storage mount point"
    return 1
  elif ! mount "/dev/${iso_loop_device}" "${ISO_STOR_PATH}"; then
    logError "Failed to mount ISO storage"
    return 1
  else
    logInfo "ISO storage mounted: ${ISO_STOR_PATH}"
  fi

  # Create the SR record for the ISO storage
  if ! xe_stor_create_iso res "${ISO_STOR_NAME}" "${ISO_STOR_PATH}"; then
    logError "Failed to create SR record for ISO storage"
    return 1
  else
    logInfo "SR record created for ISO storage: ${res}"
  fi

  # Save the configuration as created
  if ! config_save "${STOR_FILE}" STOR_STATE created; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage created"
  fi

  # If we reached here, everything was created successfully. Now unload it all
  res=0
  if ! xe_stor_unplug "${VM_STOR_NAME}"; then
    logError "Failed to unplug VM storage"
    res=1
  elif ! disk_remove_raid "${VM_STOR_DRIVE}"; then
    logError "Failed to remove RAID array"
    res=1
  elif ! disk_remove_loop "${vm_loop_device}"; then
    logError "Failed to remove loop device for VM storage"
    res=1
  else
    logInfo "VM Storage disconnected"
  fi

  if ! xe_stor_unplug "${ISO_STOR_NAME}"; then
    logError "Failed to unplug ISO storage"
    res=1
  elif ! umount "${ISO_STOR_PATH}"; then
    logError "Failed to unmount ISO storage"
    res=1
  elif ! disk_remove_loop "${iso_loop_device}"; then
    logError "Failed to remove loop device for ISO storage"
    res=1
  else
    logInfo "ISO storage disconnected"
  fi

  # shellcheck disable=SC2248
  return ${res}
}

storage_design() {
  local boot_drive
  local boot_partition
  local local_drives

  if ! disk_list_drives local_drives; then
    logError "Failed to retrieve local drives"
    return 1
  else
    logInfo "There are ${#local_drives[@]} local drives: ${local_drives[*]}"
  fi

  if ! disk_root_partition boot_drive boot_partition; then
    logError "Failed to retrieve boot drive and partition"
    return 1
  else
    logInfo "There are ${#boot_drive[@]} boot drives: ${boot_drive[*]}. Booting on ${boot_partition}"
  fi

  # Build an associative array of drives and their sizes
  declare -A drive_sectors
  declare -A drive_sector_sizes
  declare -A drive_physical_sectors
  declare -A drive_start_sectors
  declare -A drive_end_sectors
  local drive
  local nb_sectors
  local size_sectors
  local phys_sectors
  local start_sector
  local end_sector
  for drive in "${local_drives[@]}"; do
    # Get the size of the drive
    if disk_drive_size nb_sectors size_sectors phys_sectors "${drive}"; then
      drive_sectors["${drive}"]="${nb_sectors}"
      drive_sector_sizes["${drive}"]="${size_sectors}"
      drive_physical_sectors["${drive}"]="${phys_sectors}"
    else
      logError "Failed to get size of: ${drive}"
      return 1
    fi
    # Get available space
    if disk_get_available start_sector end_sector "${boot_partition}" "${drive}"; then
      drive_start_sectors["${drive}"]="${start_sector}"
      drive_end_sectors["${drive}"]="${end_sector}"
    else
      logError "Failed to get available space on ${drive}"
      return 1
    fi
  done

  logInfo <<EOF
Summary for all drives:
$(for drive in "${local_drives[@]}"; do
    __avail=$((${drive_end_sectors[${drive}]} - ${drive_start_sectors[${drive}]}))
    __availGiB=$((__avail * 512 / 1024 / 1024 / 1024))
    echo ""
    echo "Drive: ${drive}"
    echo "  Size: ${drive_sectors[${drive}]} sectors"
    echo "  Sector size: ${drive_sector_sizes[${drive}]}"
    echo "  Physical sector size: ${drive_physical_sectors[${drive}]}"
    echo "  Available space: ${__avail} sectors (${__availGiB} GiB)"
    echo "    Start sector     : ${drive_start_sectors[${drive}]}"
    echo "    End sector       : ${drive_end_sectors[${drive}]}"
  done)
EOF

  local biggest_drive
  local second_biggest_drive
  local biggest_size=0
  local second_biggest_size=0
  for drive in "${local_drives[@]}"; do
    __avail=$((${drive_end_sectors[${drive}]} - ${drive_start_sectors[${drive}]}))
    if ((__avail > biggest_size)); then
      second_biggest_size=${biggest_size}
      second_biggest_drive=${biggest_drive}
      biggest_size=${__avail}
      biggest_drive=${drive}
    elif ((__avail > second_biggest_size)); then
      second_biggest_size=${__avail}
      second_biggest_drive=${drive}
    fi
  done

  logInfo <<EOF
The biggest drive is ${biggest_drive} with ${biggest_size} sectors
The second biggest drive is ${second_biggest_drive} with ${second_biggest_size} sectors
EOF

  if [[ ${second_biggest_size} -lt $((10 * 1024 * 1024 * 1024 / 512)) ]]; then
    logError "We need at least two drives with 10+ GiB of space available"
    return 1
  fi

  # Curreny only support the second device being leftover space from a raid array
  if [[ ${drive_start_sectors[${biggest_drive}]} -le 0 ]]; then
    logError "Don't know how to configure with an empty drive"
    return 1
  fi

  # Currently only support the first device being an empty drive
  if [[ ${drive_start_sectors[${second_biggest_drive}]} -ne 0 ]]; then
    logError "Can only configure using an empty drive"
    return 1
  fi

  # Save the configuration for the VM_STORAGE drive
  if ! config_save "${STOR_FILE}" VM_STOR_DRIVE1 "${second_biggest_drive}"; then
    logError "Failed to save VM_STOR_DRIVE1"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_DRIVE2 "${biggest_drive}"; then
    logError "Failed to save VM_STOR_DRIVE2"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_DRIVE1_START "${drive_start_sectors[${second_biggest_drive}]}"; then
    logError "Failed to save VM_STOR_DRIVE1_START"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_DRIVE2_START "${drive_start_sectors[${biggest_drive}]}"; then
    logError "Failed to save VM_STOR_DRIVE2_START"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_SIZE "${second_biggest_size}"; then
    logError "Failed to save VM_STOR_SIZE"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_DRIVE "md10"; then
    logError "Failed to save VM_STOR_DRIVE"
    return 1
  elif ! config_save "${STOR_FILE}" VM_STOR_NAME "qnap_vm"; then
    logError "Failed to save VM_STOR_NAME"
    return 1
  else
    logInfo "Storage configuration saved for VM storage"
  fi

  # Adjust Biggest drive
  drive_start_sectors[${biggest_drive}]=$((${drive_start_sectors[${biggest_drive}]} + second_biggest_size))

  # Calculate parameters for ISO_STOR, alignned to the next physical sector
  local iso_store_start=${drive_start_sectors[${biggest_drive}]}
  local align_value=$((${drive_physical_sectors[${biggest_drive}]} / 512))
  if ((align_value * 512 != ${drive_physical_sectors[${biggest_drive}]})); then
    logWarn "Physical sector size is not a multiple of 512"
  else
    iso_store_start=$((iso_store_start + align_value - (iso_store_start % align_value)))
  fi
  local iso_store_size=$((${drive_end_sectors[${biggest_drive}]} - iso_store_start))

  # Make sure ISO storage is at least 5 GiB in size
  if [[ ${iso_store_size} -lt $((5 * 1024 * 1024 * 1024 / 512)) ]]; then
    logError "Not enough space for ISO storage"
    return 1
  fi

  logInfo <<EOF
ISO storage configuration:
  Device: ${biggest_drive}
  Start sector: ${iso_store_start}
  Size: ${iso_store_size} sectors ($((iso_store_size * 512 / 1024 / 1024 / 1024)) GiB)
EOF

  # Save the configuration for the ISO storage drive
  if ! config_save "${STOR_FILE}" ISO_STOR_DRIVE "${biggest_drive}"; then
    logError "Failed to save ISO_STOR_DRIVE"
    return 1
  elif ! config_save "${STOR_FILE}" ISO_STOR_START "${iso_store_start}"; then
    logError "Failed to save ISO_STOR_START"
    return 1
  elif ! config_save "${STOR_FILE}" ISO_STOR_SIZE "${iso_store_size}"; then
    logError "Failed to save ISO_STOR_SIZE"
    return 1
  elif ! config_save "${STOR_FILE}" ISO_STOR_PATH "/mnt/iso_store"; then
    logError "Failed to save ISO_STOR_PATH"
    return 1
  elif ! config_save "${STOR_FILE}" ISO_STOR_NAME "qnap_iso"; then
    logError "Failed to save ISO_STOR_NAME"
    return 1
  else
    logInfo "Storage configuration saved for ISO storage"
  fi

  # Commit this design
  if ! config_save "${STOR_FILE}" STOR_STATE designed; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage design saved"
  fi

  return 0
}

# External variables loaded
CONFIG_DIR=""
VM_STOR_DRIVE=""
ISO_STOR_PATH=""
ISO_STOR_NAME=""
VM_STOR_NAME=""

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
SR_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${SR_SOURCE}" ]]; do # resolve $SR_SOURCE until the file is no longer a symlink
  SR_ROOT=$(cd -P "$(dirname "${SR_SOURCE}")" >/dev/null 2>&1 && pwd)
  SR_SOURCE=$(readlink "${SR_SOURCE}")
  [[ ${SR_SOURCE} != /* ]] && SR_SOURCE=${SR_ROOT}/${SR_SOURCE} # if $SR_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SR_ROOT=$(cd -P "$(dirname "${SR_SOURCE}")" >/dev/null 2>&1 && pwd)
SR_ROOT=$(realpath "${SR_ROOT}/../..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
SETUP_REPO_DIR="${SR_ROOT}/external/setup"
XE_REPO_DIR="${SR_ROOT}/external/xapi.sh"
# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/config.sh"; then
  logFatal "Failed to import config.sh"
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/disk.sh"; then
  logFatal "Failed to import config.sh"
fi
# shellcheck disable=SC1091
if ! source "${XE_REPO_DIR}/src/xe_storage.sh"; then
  logFatal "Failed to import config.sh"
fi

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  logFatal "This script cannot be piped"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  logFatal "This script cannot be executed"
fi
