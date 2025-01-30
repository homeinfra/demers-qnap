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
  elif [[ -z "${XCP_VM_SR_NAME}" ]]; then
    logError "Missing XCP_VM_SR_NAME"
    return 1
  elif [[ -z "${XCP_ISO_SR_NAME}" ]]; then
    logError "Missing XCP_ISO_SR_NAME"
    return 1
  elif [[ -z "${VM_STOR_DRIVE}" ]]; then
    logError "Missing VM_STOR_DRIVE"
    return 1
  fi

  # Validate current state
  case ${STOR_STATE} in
  created)
    :
    ;;
  mounted)
    :
    ;;
  *)
    logError "Invalid state for storage: ${STOR_STATE}"
    return 1
    ;;
  esac

  # Validat that the configuration makes sense

  # Only support the case where DISK2 isn't at the beggining of the drive. We need to mount a loop device for it
  if [[ ${VM_STOR_DRIVE1_START} -ne 0 ]] || [[ ${VM_STOR_DRIVE2_START} -le 0 ]] || [[ ${VM_STOR_SIZE} -le 0 ]]; then
    logError "Invalid configuration for VM storage: ${VM_STOR_DRIVE1_START} ${VM_STOR_DRIVE2_START} ${VM_STOR_SIZE}"
    return 1
  fi

  # Only support the case where storage isn't at the beginning of the drive. We need to mount a loop device for it
  if [[ ${ISO_STOR_START} -le 0 ]] || [[ ${ISO_STOR_SIZE} -le 0 ]]; then
    logError "Invalid configuration for ISO storage: ${ISO_STOR_START} ${ISO_STOR_SIZE}"
    return 1
  fi

  # Check if necessary loop devices are already created or not
  local loop_devices loop_device vm_loop_device iso_loop_device
  if ! disk_list_loop loop_devices; then
    logError "Failed to list loop devices"
    return 1
  fi
  for loop_device in "${loop_devices[@]}"; do
    local back_file offset size
    if ! disk_loop_details back_file offset size "${loop_device}"; then
      logError "Failed to get details for loop device: ${loop_device}"
      return 1
    elif [[ ${back_file} == "${VM_STOR_DRIVE2}" ]] && [[ ${offset} -eq ${VM_STOR_DRIVE2_START} ]] && [[ ${size} -eq ${VM_STOR_SIZE} ]]; then
      vm_loop_device=${loop_device}
      logInfo "Found existing loop device for VM storage: ${vm_loop_device}"
      if [[ "${loop_device}" != "${VM_STOR_LOOP2}" ]]; then
        logWarn "VM_STOR_LOOP2 was expected to be ${VM_STOR_LOOP2}, but is ${loop_device}"
        if ! config_save "${STOR_FILE}" VM_STOR_LOOP2 "${vm_loop_device}"; then
          logError "Failed to save VM_STOR_LOOP2"
          return 1
        fi
        VM_STOR_LOOP2=${vm_loop_device}
      fi
      continue
    elif [[ ${back_file} == "${ISO_STOR_DRIVE}" ]] && [[ ${offset} -eq ${ISO_STOR_START} ]] && [[ ${size} -eq ${ISO_STOR_SIZE} ]]; then
      iso_loop_device=${loop_device}
      logInfo "Found existing loop device for ISO storage: ${iso_loop_device}"
      if [[ "${loop_device}" != "${ISO_STOR_LOOP}" ]]; then
        logWarn "ISO_STOR_LOOP was expected to be ${ISO_STOR_LOOP}, but is ${loop_device}"
        if ! config_save "${STOR_FILE}" ISO_STOR_LOOP "${iso_loop_device}"; then
          logError "Failed to save ISO_STOR_LOOP"
          return 1
        fi
        ISO_STOR_LOOP=${iso_loop_device}
      fi
      continue
    else
      logWarn "Found unexpected loop device: ${loop_device} ${back_file} ${offset} ${size}"
    fi
  done

  # First: VM Storage
  if [[ -z ${vm_loop_device} ]]; then
    logInfo "Creating loop device for VM storage"
    if ! disk_create_loop vm_loop_device "${VM_STOR_DRIVE2}" "${VM_STOR_DRIVE2_START}" "${VM_STOR_SIZE}"; then
      logError "Failed to create loop device for VM storage"
      return 1
    elif ! config_save "${STOR_FILE}" VM_STOR_LOOP2 "${vm_loop_device}"; then
      logError "Failed to save VM_STOR_LOOP2"
      return 1
    else
      logInfo "Loop device created for VM storage: ${vm_loop_device}"
    fi
  fi

  # Second: ISO Storage
  if [[ -z ${iso_loop_device} ]]; then
    logInfo "Creating loop device for ISO storage"
    if ! disk_create_loop iso_loop_device "${ISO_STOR_DRIVE}" "${ISO_STOR_START}" "${ISO_STOR_SIZE}"; then
      logError "Failed to create loop device for ISO storage"
      return 1
    elif ! config_save "${STOR_FILE}" ISO_STOR_LOOP "${iso_loop_device}"; then
      logError "Failed to save ISO_STOR_LOOP"
      return 1
    else
      logInfo "Loop device created for ISO storage: ${iso_loop_device}"
    fi
  fi

  # Assemble the RAID1 array for the VM storage
  if ! disk_assemble_radi1 "${VM_STOR_DRIVE}" "${VM_STOR_DRIVE1}" "${vm_loop_device}"; then
    logError "Failed to assemble RAID 1 array for VM storage"
    return 1
  else
    logInfo "RAID 1 array assembled for VM storage"
  fi

  # Check if ISO storage is already mounted
  local res
  # shellcheck disable=SC2312 # Grep will fail anyway it doesn't find the string
  if ! mount | grep -q "${ISO_STOR_PATH}"; then
    logInfo "Mounting ISO storage"
    if ! sh_exec "" mount "/dev/${iso_loop_device}" "${ISO_STOR_PATH}"; then
      logError "Failed to mount ISO storage"
      return 1
    else
      logInfo "ISO storage mounted"
    fi
  else
    logInfo "ISO storage already mounted"
  fi

  # Symlink the XCP-ng tools ISO to the ISO storage
  local filename
  sh_exec filename ls -1 "${XEN_GUEST_TOOLS_ISO_DIR}"
  if [[ -z ${filename} ]]; then
    logError "Failed to find XCP-ng tools ISO"
    return 1
  elif [[ ! -f "${XEN_GUEST_TOOLS_ISO_DIR}/${filename}" ]]; then
    logError "XCP-ng tools ISO doesn't exist"
    return 1
  elif [[ -L "${ISO_STOR_PATH}/${XEN_GUEST_TOOLS_NAME}" ]]; then
    logInfo "XCP-ng tools ISO already symlinked"
  elif ! ln -s "${XEN_GUEST_TOOLS_ISO_DIR}/${filename}" "${ISO_STOR_PATH}/${XEN_GUEST_TOOLS_NAME}"; then
    logError "Failed to symlink XCP-ng tools ISO"
    return 1
  else
    logInfo "XCP-ng tools ISO symlinked"
  fi

  # Plug the storage
  if ! xe_stor_plug "${XCP_VM_SR_NAME}"; then
    logError "Failed to plug VM storage"
    return 1
  elif ! xe_stor_plug "${XCP_ISO_SR_NAME}"; then
    logError "Failed to plug ISO storage"
    return 1
  else
    logInfo "Storage connected"
  fi

  # Save the configuration as mounted
  if ! config_save "${STOR_FILE}" STOR_STATE mounted; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage mounted"
  fi

  # Also setup storage used by NAS
  if ! nas_storage_mount; then
    logError "Failed to setup NAS storage"
    return 1
  fi

  return 0
}

storage_unmount() {
  local __return_code=0

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
    :
    ;;
  *)
    logError "Invalid state for storage: ${STOR_STATE}"
    return 1
    ;;
  esac

  # First: NAS Storage
  if ! nas_storage_unmount; then
    logError "Failed to unmount NAS storage"
    __return_code=1
  fi

  # Second: ISO Storage
  if ! xe_stor_unplug "${XCP_ISO_SR_NAME}"; then
    logError "Failed to unplug ISO storage"
    __return_code=1
  fi
  if [[ -L "${ISO_STOR_PATH}/${XEN_GUEST_TOOLS_NAME}" ]]; then
    if ! rm "${ISO_STOR_PATH}/${XEN_GUEST_TOOLS_NAME}"; then
      logError "Failed to remove symlink for XCP-ng tools ISO"
      __return_code=1
    else
      logInfo "XCP-ng tools ISO symlink removed"
    fi
  else
    logInfo "XCP-ng tools ISO symlink already removed"
  fi
  # shellcheck disable=SC2312 # Grep will fail anyway it doesn't find the string
  if mount | grep -q "${ISO_STOR_PATH}"; then
    if ! sh_exec "" umount "${ISO_STOR_PATH}"; then
      logError "Failed to unmount ISO storage"
      __return_code=1
    else
      logInfo "ISO storage unmounted"
    fi
  else
    logInfo "ISO storage already unmounted"
  fi
  if [[ -z ${ISO_STOR_LOOP} ]]; then
    logError "Missing loop device for ISO storage"
    __return_code=1
  elif ! disk_remove_loop "${ISO_STOR_LOOP}"; then
    logError "Failed to remove loop device for ISO storage"
    __return_code=1
  else
    logInfo "Loop device removed for ISO storage"
  fi
  if ! config_save "${STOR_FILE}" ISO_STOR_LOOP ""; then
    logError "Failed to remove ISO_STOR_LOOP"
    __return_code=1
  else
    logInfo "ISO storage disconnected"
  fi

  # Third: VM Storage
  if ! xe_stor_unplug "${XCP_VM_SR_NAME}"; then
    logError "Failed to unplug VM storage"
    __return_code=1
  fi
  if ! disk_remove_raid "${VM_STOR_DRIVE}"; then
    logError "Failed to remove RAID array for VM storage"
    __return_code=1
  fi
  if [[ -z ${VM_STOR_LOOP2} ]]; then
    logError "Missing loop device for VM storage"
    __return_code=1
  elif ! disk_remove_loop "${VM_STOR_LOOP2}"; then
    logError "Failed to remove loop device for VM storage"
    __return_code=1
  fi
  if ! config_save "${STOR_FILE}" VM_STOR_LOOP2 ""; then
    logError "Failed to remove VM_STOR_LOOP2"
    __return_code=1
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

  # shellcheck disable=SC2248
  return ${__return_code}
}

storage_create() {
  if [[ -z ${VM_STOR_DRIVE1} ]] || [[ -z ${VM_STOR_DRIVE2} ]] || [[ -z ${VM_STOR_DRIVE1_START} ]] || [[ -z ${VM_STOR_DRIVE2_START} ]] || [[ -z ${VM_STOR_SIZE} ]]; then
    # Are we given parameters for VM Storage
    logError "Missing configuration for VM storage"
    return 1
  elif [[ "${VM_STOR_DRIVE1}" == "${VM_STOR_DRIVE2}" ]]; then
    # Make sure VM Storage consist of two different drives (for RAID1)
    logError "VM storage drives are the same"
    return 1
  elif [[ ${VM_STOR_DRIVE1_START} -ne 0 ]] || [[ ${VM_STOR_DRIVE2_START} -le 0 ]] || [[ ${VM_STOR_SIZE} -le 0 ]]; then
    # Currently we only support the scenario where DRIVE1 is at the beginning of the drive and DRIVE2 isn't
    logError "Invalid configuration for VM storage"
    return 1
  elif [[ -z ${ISO_STOR_DRIVE} ]] || [[ -z ${ISO_STOR_START} ]] || [[ -z ${ISO_STOR_SIZE} ]] || [[ -z ${ISO_STOR_PATH} ]]; then
    # Are we given parameters for ISO Storage
    logError "Missing configuration for ISO storage"
    return 1
  elif [[ ${ISO_STOR_START} -le 0 ]] || [[ ${ISO_STOR_SIZE} -le 0 ]]; then
    # Currently we only support the scenario where DRIVE isn't at the beginning of the drive
    logError "Invalid configuration for ISO storage"
    return 1
  fi

  local vm_loop_device
  local iso_loop_device
  local res=0

  ################
  ## VM Storage ##
  ################
  # First, wipe the first 34 sectors of both drives
  if ! sh_exec "" dd if=/dev/zero of="${VM_STOR_DRIVE1}" bs=512 count=34 seek="${VM_STOR_DRIVE1_START}"; then
    logError "Failed to erase first 34 sectors of ${VM_STOR_DRIVE1}"
    return 1
  elif ! sh_exec "" dd if=/dev/zero of="${VM_STOR_DRIVE2}" bs=512 count=34 seek="${VM_STOR_DRIVE2_START}"; then
    logError "Failed to erase first 34 sectors of ${VM_STOR_DRIVE2}"
    return 1
  else
    logInfo "First 34 sectors erased on both drives"
  fi

  # Second, create a virtual device, needed because DRIVE2 doen't start at offset 0
  if ! disk_create_loop vm_loop_device "${VM_STOR_DRIVE2}" "${VM_STOR_DRIVE2_START}" "${VM_STOR_SIZE}"; then
    logError "Failed to create loop device for VM storage"
    return 1
  else
    logInfo "Loop device created for VM storage: ${vm_loop_device}"
  fi

  # Third, create the RAID1 array itself
  if ! disk_create_raid1 "${VM_STOR_DRIVE}" "${VM_STOR_DRIVE1}" "${vm_loop_device}"; then
    logError "Failed to create RAID1 array for VM storage"
    return 1
  else
    logInfo "RAID1 array created for VM storage"
  fi

  # Fourth, create the XCP-ng Storage Record (SR) on this new drive
  if ! xe_stor_create_lvm res "${XCP_VM_SR_NAME}" "${VM_STOR_DRIVE}"; then
    logError "Failed to create SR record for VM storage"
    return 1
  else
    logInfo "SR record created for VM storage: ${res}"
  fi

  #################
  ## ISO Storage ##
  #################

  # First, wipe the first 34 sectors of the drive
  if ! sh_exec "" dd if=/dev/zero of="${ISO_STOR_DRIVE}" bs=512 count=34 seek="${ISO_STOR_START}"; then
    logError "Failed to erase first 34 sectors of ${ISO_STOR_DRIVE}"
    return 1
  else
    logInfo "First 34 sectors erased on ${ISO_STOR_DRIVE}"
  fi

  # Second, create a virtual device, needed because DRIVE doen't start at offset 0
  if ! disk_create_loop iso_loop_device "${ISO_STOR_DRIVE}" "${ISO_STOR_START}" "${ISO_STOR_SIZE}"; then
    logError "Failed to create loop device for ISO storage"
    return 1
  else
    logInfo "Loop device created for ISO storage: ${iso_loop_device}"
  fi

  # Third, format the ISO storage
  if ! disk_format "${iso_loop_device}" "ext4"; then
    logError "Failed to format ISO storage"
    return 1
  else
    logInfo "ISO storage formatted"
  fi

  # Fourth, mount the ISO storage
  if ! sh_exec "" mkdir -p "${ISO_STOR_PATH}"; then
    logError "Failed to create ISO storage mount point"
    return 1
  elif ! sh_exec "" mount "/dev/${iso_loop_device}" "${ISO_STOR_PATH}"; then
    logError "Failed to mount ISO storage"
    return 1
  else
    logInfo "ISO storage mounted: ${ISO_STOR_PATH}"
  fi

  # Fifth, create the XCP-ng Storage Record (SR) on it
  if ! xe_stor_create_iso res "${XCP_ISO_SR_NAME}" "${ISO_STOR_PATH}"; then
    logError "Failed to create SR record for ISO storage"
    return 1
  else
    logInfo "SR record created for ISO storage: ${res}"
  fi

  ##############
  ## Epîlogue ##
  ##############

  # Save the configuration as created
  if ! config_save "${STOR_FILE}" STOR_STATE created; then
    logError "Failed to save STOR_STATE"
    return 1
  else
    logInfo "Storage created"
  fi

  # If we reached here, everything was created successfully. Now unload it all
  res=0
  if ! xe_stor_unplug "${XCP_VM_SR_NAME}"; then
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

  if ! xe_stor_unplug "${XCP_ISO_SR_NAME}"; then
    logError "Failed to unplug ISO storage"
    res=1
  elif ! sh_exec "" umount "${ISO_STOR_PATH}"; then
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

  local __avail __availGiB
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
    __availGiB=$((__avail * 512 / 1024 / 1024 / 1024))
    # Ignore drives that are over 1TiB.
    # This is probably intended for NAS/SAN and not local storage.
    if ((__availGiB > 1024)); then
      logWarn "Ignoring drive ${drive} with ${__avail} sectors (${__availGiB} GiB)"
      continue
    fi
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

# Constants
XEN_GUEST_TOOLS_ISO_DIR="/opt/xensource/packages/iso"
XEN_GUEST_TOOLS_NAME="guest-tools.iso"

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
if ! source "${SR_ROOT}/src/storage/nas.sh"; then
  logFatal "Failed to import nas.sh"
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/disk.sh"; then
  logFatal "Failed to import disk.sh"
fi
# shellcheck disable=SC1091
if ! source "${XE_REPO_DIR}/src/xe_storage.sh"; then
  logFatal "Failed to import xe_storage.sh"
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
