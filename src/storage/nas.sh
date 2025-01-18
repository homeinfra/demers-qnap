# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script configures the storage that will be dedicated to a NAS

if [[ -z ${GUARD_NAS_SH} ]]; then
  GUARD_NAS_SH=1
else
  logWarn "Re-sourcing nas.sh"
  return 0
fi

nas_storage_setup() {
  if ! nas_identify_disks; then
    return 1
  fi
  if ! nas_storage_update; then
    return 1
  fi
}

nas_storage_mount() {
  nas_storage_setup
  return $?
}

# Unmount the NAS SR (usually during shutdown)
nas_storage_unmount() {
  local state res create

  # Validate requirements
  if [[ -z "${NAS_STOR_NAME}" ]]; then
    logError "NAS_STOR_NAME is not set"
    return 1
  elif [[ -z "${VM_NAME_NAS}" ]]; then
    logError "VM_NAME_NAS is not set"
    return 1
  fi

  # Make sure the NAS is not running
  if ! xe_vm_state state "${VM_NAME_NAS}"; then
    logError "Failed to get NAS state"
    return 1
  fi
  if [[ "${state}" != "halted" ]] && [[ "${state}" != "not_exist" ]]; then
    logError "NAS must be stopped first, before cutting the grass under it's feet"
    return 1
  fi
  # Check if a SR exists
  xe_stor_uuid_by_name state "${NAS_STOR_NAME}"
  res=$?
  if [[ ${res} -eq 1 ]]; then
    logError "Failed to check the existence of the NAS SR"
    return 1
  elif [[ ${res} -eq 2 ]]; then
    logInfo "NAS SR does not exist"
    create=1
  fi

  if [[ ${create} -eq 0 ]]; then
    # Make sure the SR is unplugged
    if ! xe_stor_unplug "${NAS_STOR_NAME}"; then
      logError "Failed to unplug the NAS SR"
      return 1
    fi
  fi
}

# Identify disks and store that information
nas_identify_disks() {
  local nas_config_file config_dirty

  if [[ -z "${CONFIG_DIR}" ]]; then
    logError "CONFIG_DIR is not set"
    return 1
  fi
  nas_config_file="${CONFIG_DIR}/nas.env"

  # Assume dirty by default
  config_dirty=1

  if [[ -f "${nas_config_file}" ]]; then
    logInfo "NAS configuration file already exists"
    if ! config_load "${nas_config_file}"; then
      logError "Failed to load NAS configuration"
      return 1
    else
      config_dirty=0
    fi
  fi

  # shellcheck disable=SC2034
  local disk_list candicate_disks
  if ! disk_list_drives disk_list; then
    logError "Failed to list drives"
    return 1
  fi

  # shellcheck disable=SC2034
  local nb_sectors size_sectors phys_sectors size size_gib
  candidate_disks=()
  for disk in "${disk_list[@]}"; do
    if ! disk_drive_size nb_sectors size_sectors phys_sectors "${disk}"; then
      logError "Failed to get size of ${disk}"
      return 1
    fi
    size=$((nb_sectors * 512))
    size_gib=$((size / 1024 / 1024 / 1024))

    # Only consider drives that are at least 1 TiB in size
    if [[ ${size_gib} -ge 1024 ]]; then
      candidate_disks+=("${disk}")
    fi
  done

  # Sanity check, we expect to find exactly 6 disks
  if [[ ${#candidate_disks[@]} -ne 6 ]]; then
    logError "Expected to find 6 disks, found ${#candidate_disks[@]}"
    return 1
  fi

  # Identify the disks
  declare -A controller_1 controller_4
  local tmp_D1_DEV tmp_D2_DEV tmp_D3_DEV tmp_D4_DEV tmp_D5_DEV tmp_D6_DEV
  local tmp_D1_PATH tmp_D2_PATH tmp_D3_PATH tmp_D4_PATH tmp_D5_PATH tmp_D6_PATH
  local tmp_D1_SN tmp_D2_SN tmp_D3_SN tmp_D4_SN tmp_D5_SN tmp_D6_SN
  local tmp_D1_WWN tmp_D2_WWN tmp_D3_WWN tmp_D4_WWN tmp_D5_WWN tmp_D6_WWN
  local d_path d_sn d_wwn c1_count c4_count
  c1_count=0
  c4_count=0
  for disk in "${candidate_disks[@]}"; do
    if ! disk_get_info d_path d_sn d_wwn "${disk}"; then
      logError "Failed to get info for ${disk}"
      return 1
    fi
    if [[ "${d_path}" == "/devices/pci0000:00/0000:00:11.0"* ]]; then
      # There will be two drives in controller 1, for Disk 1 and Disk 2
      c1_count=$((c1_count + 1))
      if [[ ${c1_count} -gt 2 ]]; then
        logError "Too many drives on controller 1"
        return 1
      fi
      controller_1["Disk${c1_count}"]="${disk}"
      controller_1["Disk${c1_count}_PATH"]="${d_path}"
      controller_1["Disk${c1_count}_SN"]="${d_sn}"
      controller_1["Disk${c1_count}_WWN"]="${d_wwn}"
    elif [[ "${d_path}" == "/devices/pci0000:00/0000:00:02.2/0000:07:00.0"* ]]; then
      # There will be only one drive on controller 2, for Disk 3
      if [[ -n "${tmp_D3_DEV}" ]]; then
        logError "Disk 3 already identified. There should only be one"
        return 1
      fi
      tmp_D3_DEV="${disk}"
      # shellcheck disable=SC2034
      tmp_D3_PATH="${d_path}"
      # shellcheck disable=SC2034
      tmp_D3_SN="${d_sn}"
      # shellcheck disable=SC2034
      tmp_D3_WWN="${d_wwn}"
    elif [[ "${d_path}" == "/devices/pci0000:00/0000:00:02.3/0000:08:00.0"* ]]; then
      # There will be only one drive on controller 3, for Disk 4
      if [[ -n "${tmp_D4_DEV}" ]]; then
        logError "Disk 4 already identified. There should only be one"
        return 1
      fi
      tmp_D4_DEV="${disk}"
      # shellcheck disable=SC2034
      tmp_D4_PATH="${d_path}"
      # shellcheck disable=SC2034
      tmp_D4_SN="${d_sn}"
      # shellcheck disable=SC2034
      tmp_D4_WWN="${d_wwn}"
    elif [[ "${d_path}" == "/devices/pci0000:00/0000:00:02.4/0000:09:00.0"* ]]; then
      # There will be two drives in controller 4, for Disk 5 and Disk 6
      c4_count=$((c4_count + 1))
      if [[ ${c4_count} -gt 2 ]]; then
        logError "Too many drives on controller 4"
        return 1
      fi
      controller_4["Disk${c4_count}"]="${disk}"
      controller_4["Disk${c4_count}_PATH"]="${d_path}"
      controller_4["Disk${c4_count}_SN"]="${d_sn}"
      controller_4["Disk${c4_count}_WWN"]="${d_wwn}"
    else
      logError "Unknown controller for ${disk}"
      return 1
    fi
  done

  # If we are here, we've iterated 6 times and identified all our disks
  # We must now discriminate on controller 1 and 4
  if [[ ${c1_count} -ne 2 ]]; then
    logError "Expected 2 disks on controller 1, found ${c1_count}"
    return 1
  fi
  if [[ ${c4_count} -ne 2 ]]; then
    logError "Expected 2 disks on controller 4, found ${c4_count}"
    return 1
  fi

  local ata1 ata2
  # On controller 1, Disk 1 should have a lower ATA number than Disk 2
  ata1=$(echo "${controller_1["Disk1_PATH"]}" | awk -F'/' '{for (i=1; i<=NF; i++) if ($i ~ /ata/) {print $i; exit}}')
  ata2=$(echo "${controller_1["Disk2_PATH"]}" | awk -F'/' '{for (i=1; i<=NF; i++) if ($i ~ /ata/) {print $i; exit}}')
  logTrace "Candidate Disk 1: ${ata1}, Candidate Disk 2: ${ata2}"
  if [[ "${ata1}" > "${ata2}" ]]; then
    # The bigger is Disk 2
    logInfo "Disk 1 has a higher ata number than Disk 2, reversing"
    tmp_D2_DEV="${controller_1["Disk1"]}"
    tmp_D2_PATH="${controller_1["Disk1_PATH"]}"
    tmp_D2_SN="${controller_1["Disk1_SN"]}"
    tmp_D2_WWN="${controller_1["Disk1_WWN"]}"
    tmp_D1_DEV="${controller_1["Disk2"]}"
    tmp_D1_PATH="${controller_1["Disk2_PATH"]}"
    tmp_D1_SN="${controller_1["Disk2_SN"]}"
    tmp_D1_WWN="${controller_1["Disk2_WWN"]}"
  else
    # The smaller is Disk 1
    logInfo "Disk 2 has a higher ata number than Disk 1, approving"
    # shellcheck disable=SC2034
    tmp_D1_DEV="${controller_1["Disk1"]}"
    # shellcheck disable=SC2034
    tmp_D1_PATH="${controller_1["Disk1_PATH"]}"
    # shellcheck disable=SC2034
    tmp_D1_SN="${controller_1["Disk1_SN"]}"
    # shellcheck disable=SC2034
    tmp_D1_WWN="${controller_1["Disk1_WWN"]}"
    # shellcheck disable=SC2034
    tmp_D2_DEV="${controller_1["Disk2"]}"
    # shellcheck disable=SC2034
    tmp_D2_PATH="${controller_1["Disk2_PATH"]}"
    # shellcheck disable=SC2034
    tmp_D2_SN="${controller_1["Disk2_SN"]}"
    # shellcheck disable=SC2034
    tmp_D2_WWN="${controller_1["Disk2_WWN"]}"
  fi

  # On controller 4, Disk 5 should have a lower ATA number than Disk 6
  ata1=$(echo "${controller_4["Disk1_PATH"]}" | awk -F'/' '{for (i=1; i<=NF; i++) if ($i ~ /ata/) {print $i; exit}}')
  ata2=$(echo "${controller_4["Disk2_PATH"]}" | awk -F'/' '{for (i=1; i<=NF; i++) if ($i ~ /ata/) {print $i; exit}}')
  logTrace "Candidate Disk 5: ${ata1}, Candidate Disk 6: ${ata2}"
  if [[ "${ata1}" > "${ata2}" ]]; then
    # The bigger is Disk 6
    logInfo "Disk 5 has a higher ata number than Disk 6, reversing"
    tmp_D6_DEV="${controller_4["Disk1"]}"
    tmp_D6_PATH="${controller_4["Disk1_PATH"]}"
    tmp_D6_SN="${controller_4["Disk1_SN"]}"
    tmp_D6_WWN="${controller_4["Disk1_WWN"]}"
    tmp_D5_DEV="${controller_4["Disk2"]}"
    tmp_D5_PATH="${controller_4["Disk2_PATH"]}"
    tmp_D5_SN="${controller_4["Disk2_SN"]}"
    tmp_D5_WWN="${controller_4["Disk2_WWN"]}"
  else
    # The smaller is Disk 5
    logInfo "Disk 6 has a higher ata number than Disk 5, approving"
    # shellcheck disable=SC2034
    tmp_D5_DEV="${controller_4["Disk1"]}"
    # shellcheck disable=SC2034
    tmp_D5_PATH="${controller_4["Disk1_PATH"]}"
    # shellcheck disable=SC2034
    tmp_D5_SN="${controller_4["Disk1_SN"]}"
    # shellcheck disable=SC2034
    tmp_D5_WWN="${controller_4["Disk1_WWN"]}"
    # shellcheck disable=SC2034
    tmp_D6_DEV="${controller_4["Disk2"]}"
    # shellcheck disable=SC2034
    tmp_D6_PATH="${controller_4["Disk2_PATH"]}"
    # shellcheck disable=SC2034
    tmp_D6_SN="${controller_4["Disk2_SN"]}"
    # shellcheck disable=SC2034
    tmp_D6_WWN="${controller_4["Disk2_WWN"]}"
  fi

  # Our 6 disks are fully identified. Store and print the information
  local d_count
  local var_old_dev var_old_path var_old_sn var_old_wwn
  local var_new_dev var_new_path var_new_sn var_new_wwn
  local logOutput
  for d_count in 1 2 3 4 5 6; do
    var_old_dev="D${d_count}_DEV"
    var_old_path="D${d_count}_PATH"
    var_old_sn="D${d_count}_SN"
    var_old_wwn="D${d_count}_WWN"
    var_new_dev="tmp_D${d_count}_DEV"
    var_new_path="tmp_D${d_count}_PATH"
    var_new_sn="tmp_D${d_count}_SN"
    var_new_wwn="tmp_D${d_count}_WWN"

    logOutput+="Disk ${d_count}:\n"
    # Compare old and new values
    if [[ "${!var_old_dev}" != "${!var_new_dev}" ]]; then
      if [[ -n "${!var_old_dev}" ]]; then
        logOutput+="  Device: ${!var_old_dev} -> ${!var_new_dev}\n"
      else
        logOutput+="  Device: ${!var_new_dev} (new)\n"
      fi
      config_save "${nas_config_file}" "${var_old_dev}" "${!var_new_dev}"
      config_dirty=1
    else
      logOutput+="  Device: ${!var_old_dev}\n"
    fi
    if [[ "${!var_old_path}" != "${!var_new_path}" ]]; then
      if [[ -n "${!var_old_path}" ]]; then
        logOutput+="  Path: ${!var_old_path} -> ${!var_new_path}\n"
      else
        logOutput+="  Path: ${!var_new_path} (new)\n"
      fi
      config_save "${nas_config_file}" "${var_old_path}" "${!var_new_path}"
      config_dirty=1
    else
      logOutput+="  Path: ${!var_old_path}\n"
    fi
    if [[ "${!var_old_sn}" != "${!var_new_sn}" ]]; then
      if [[ -n "${!var_old_sn}" ]]; then
        logOutput+="  SN: ${!var_old_sn} -> ${!var_new_sn}\n"
      else
        logOutput+="  SN: ${!var_new_sn} (new)\n"
      fi
      config_save "${nas_config_file}" "${var_old_sn}" "${!var_new_sn}"
      config_dirty=1
    else
      logOutput+="  SN: ${!var_old_sn}\n"
    fi
    if [[ "${!var_old_wwn}" != "${!var_new_wwn}" ]]; then
      if [[ -n "${!var_old_wwn}" ]]; then
        logOutput+="  WWN: ${!var_old_wwn} -> ${!var_new_wwn}\n"
      else
        logOutput+="  WWN: ${!var_new_wwn} (new)\n"
      fi
      config_save "${nas_config_file}" "${var_old_wwn}" "${!var_new_wwn}"
      config_dirty=1
    else
      logOutput+="  WWN: ${!var_old_wwn}\n"
    fi
  done

  logTrace "\nWe have the following drive configuration:\n${logOutput}"

  # Make sure the SR name is configured
  if [[ -z "${NAS_STOR_NAME}" ]]; then
    NAS_STOR_NAME="${DEFAULT_NAS_STOR_NAME}"
    if ! config_save "${CONFIG_DIR}/storage.env" "NAS_STOR_NAME" "${NAS_STOR_NAME}"; then
      logError "Failed to save NAS SR name"
      return 1
    fi
  fi

  # Make sure the VM name is configured
  if [[ -z "${VM_NAME_NAS}" ]]; then
    VM_NAME_NAS="${DEFAULT_VM_NAME_NAS}"
    if ! config_save "${nas_config_file}" "VM_NAME_NAS" "${VM_NAME_NAS}"; then
      logError "Failed to save NAS VM name"
      return 1
    fi
  fi

  if [[ ${config_dirty} -eq 1 ]]; then
    logInfo "NAS configuration updated"
    if ! config_load "${nas_config_file}"; then
      logError "Failed to reload NAS configuration"
      return 1
    fi
    if ! config_load "${CONFIG_DIR}/storage.env"; then
      logError "Failed to reload storage configuration"
      return 1
    fi
  else
    logInfo "NAS configuration unchanged"
  fi
}

nas_storage_update() {
  local needs_update folder_nas
  needs_update=0
  folder_nas="${CONFIG_DIR}/${NAS_STOR_NAME}"

  if [[ -d "${folder_nas}" ]]; then
    logInfo "NAS SR folder already exists"
  else
    logInfo "Creating NAS SR folder"
    if ! mkdir -p "${folder_nas}"; then
      logError "Failed to create NAS SR folder"
      return 1
    fi
    needs_update=1
  fi

  local disk link cur_dev var_dev_name
  for disk in 1 2 3 4 5 6; do
    var_dev_name="D${disk}_DEV"
    link="${folder_nas}/Disk${disk}"
    if [[ -L "${link}" ]]; then
      cur_dev=$(readlink -f "${link}")
      if [[ "${cur_dev}" != "/dev/${!var_dev_name}" ]]; then
        logWarn "Link to Disk ${disk} needs update"
        needs_update=1
      else
        logTrace "Link for Disk ${disk} already up-to-date"
      fi
    else
      logInfo "Need to create link for Disk ${disk}"
      needs_update=1
    fi
  done

  local state res
  if [[ ${needs_update} -eq 1 ]]; then

    # Make sure it's unmounted first, before modifying it
    if ! nas_storage_unmount; then
      logError "Failed to unmount NAS SR first"
      return 1
    fi

    # Update all the simlinks
    for disk in 1 2 3 4 5 6; do
      var_dev_name="D${disk}_DEV"
      link="${folder_nas}/Disk${disk}"
      if [[ -L "${link}" ]]; then
        logInfo "Removing link for Disk ${disk}"
        if ! rm -f "${link}"; then
          logError "Failed to remove link for Disk ${disk}"
          return 1
        fi
      fi
      logInfo "Creating link for Disk ${disk}"
      if ! ln -s "/dev/${!var_dev_name}" "${link}"; then
        logError "Failed to create link for Disk ${disk}"
        return 1
      fi
    done

    # Check if the SR exists
    xe_stor_uuid_by_name state "${NAS_STOR_NAME}"
    res=$?
    if [[ ${res} -eq 1 ]]; then
      logError "Failed to check the existence of the NAS SR"
      return 1
    fi

    if [[ ${res} -eq 2 ]]; then
      # Create the NAS SR
      if ! xe_stor_create_udev res "${NAS_STOR_NAME}" "${folder_nas}"; then
        logError "Failed to create the NAS SR"
        return 1
      fi
    else
      # Plug the SR back in
      if ! xe_stor_plug "${NAS_STOR_NAME}"; then
        logError "Failed to plug the NAS SR"
        return 1
      fi
    fi
  fi

  return 0
}

# Variables loaded externally

# Constants
DEFAULT_NAS_STOR_NAME="qnap_nas"
DEFAULT_VM_NAME_NAS="Halley"

###########################
###### Startup logic ######
###########################

# Get directory of this script
# https://stackoverflow.com/a/246128
NAS_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${NAS_SOURCE}" ]]; do # resolve $NAS_SOURCE until the file is no longer a symlink
  NAS_ROOT=$(cd -P "$(dirname "${NAS_SOURCE}")" >/dev/null 2>&1 && pwd)
  NAS_SOURCE=$(readlink "${NAS_SOURCE}")
  [[ ${NAS_SOURCE} != /* ]] && NAS_SOURCE=${NAS_ROOT}/${NAS_SOURCE} # if $NAS_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
NAS_ROOT=$(cd -P "$(dirname "${NAS_SOURCE}")" >/dev/null 2>&1 && pwd)
NAS_ROOT=$(realpath "${NAS_ROOT}/../..")

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
SETUP_REPO_DIR="${NAS_ROOT}/external/setup"
XE_REPO_DIR="${NAS_ROOT}/external/xapi.sh"
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
if ! source "${XE_REPO_DIR}/src/xe_vm.sh"; then
  logFatal "Failed to import xe_vm.sh"
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
