#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script configures the persistent storage for the XCP-ng host

storage_setup() {
  local boot_drive
  local boot_partition
  local local_drives

  if ! disk_get_drives local_drives; then
    logError "Failed to retrieve local drives"
    return 1
  else
    logInfo "There are ${#local_drives[@]} local drives: ${local_drives[*]}"
  fi

  if ! disk_boot_partition boot_drive boot_partition; then
    logError "Failed to retrieve boot drive and partition"
    return 1
  else
    logInfo "There are ${#boot_drive[@]} boot drives: ${boot_drive[*]}. Booting on ${boot_partition}"
  fi

  # Build an associative array of drives and their sizes
  declare -A drive_sectors
  declare -A drive_sector_sizes
  declare -A drive_start_sectors
  declare -A drive_end_sectors
  local drive
  local nb_sectors
  local size_sectors
  local start_sector
  local end_sector
  for drive in "${local_drives[@]}"; do
    # Get the size of the drive
    if disk_drive_size nb_sectors size_sectors "${drive}"; then
      drive_sectors["$drive"]="${nb_sectors}"
      drive_sector_sizes["$drive"]="${size_sectors}"
    else
      logError "Failed to get size of: ${drive}"
      return 1
    fi
    # Get available space
    if disk_get_available start_sector end_sector "${boot_partition}" "${drive}"; then
      drive_start_sectors["$drive"]="${start_sector}"
      drive_end_sectors["$drive"]="${end_sector}"
    else
      logError "Failed to get available space on ${drive}"
      return 1
    fi
  done

  logInfo << EOF
Summary for all drives:
$(for drive in "${local_drives[@]}"; do
  __avail=$(( (${drive_end_sectors[$drive]} - ${drive_start_sectors[$drive]}) ))
  __availGiB=$(( ${__avail} * ${drive_sector_sizes[$drive]} / 1024 / 1024 / 1024 ))
  echo ""
  echo "Drive: ${drive}"
  echo "  Size: ${drive_sectors[$drive]} sectors"
  echo "  Sector size: ${drive_sector_sizes[$drive]}"
  echo "  Available space: ${__avail} sectors (${__availGiB} GiB)"
  echo "    Start sector     : ${drive_start_sectors[$drive]}"
  echo "    End sector       : ${drive_end_sectors[$drive]}"
done)
EOF

#     logInfo <<EOF
# We could create a partition on ${drive}:
#   Start sector     : ${start_sector}
#   End sector       : ${end_sector}
#   Number of sectors: $(( ${end_sector} - ${start_sector} ))
#   Sector size      : ${drive_sector_sizes[$drive]}
#   Size (Bytes)     : $(( (${end_sector} - ${start_sector}) * ${drive_sector_sizes[$drive]} ))
#   Size (GiB)       : $(( (${end_sector} - ${start_sector}) * ${drive_sector_sizes[$drive]} / 1024 / 1024 / 1024 ))
# EOF



  local biggest_drive
  local second_biggest_drive


  return 0
}

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

# Import dependencies
SETUP_REPO_DIR="${SR_ROOT}/external/setup"
# shellcheck disable=SC1091
if ! source "${PREFIX:-/usr/local}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck disable=SC1091
if ! source "${PREFIX:-/usr/local}/lib/config.sh"; then
  logFatal "Failed to import config.sh"
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/disk.sh"; then
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
  config_load "${SR_ROOT}/data/local.env"
  config_load "${SR_ROOT}/data/hardware.env"

  LOG_CONSOLE=1
  logSetLevel "${LEVEL_ALL}"
  storage_setup
  exit $?
fi
