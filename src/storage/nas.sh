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

# Unmount the NAS storage (usually during shutdown)
nas_storage_unmount() {
  local res

  # Validate requirements
  if [[ -z "${XCP_DRIVE_SR_NAME}" ]]; then
    logError "XCP_DRIVE_SR_NAME is not set"
    return 1
  fi

  # Check if a SR exists
  xe_stor_uuid_by_name dummy "${XCP_DRIVE_SR_NAME}"
  res=$?
  if [[ ${res} -eq 1 ]]; then
    logError "Failed to check the existence of the ${XCP_DRIVE_SR_NAME} SR"
    return 1
  elif [[ ${res} -eq 2 ]]; then
    logInfo "SR ${XCP_DRIVE_SR_NAME} does not exist"
    return 0
  else
    logTrace "SR ${XCP_DRIVE_SR_NAME} exists"
    local users_uuids
    if ! xe_vm_list_by_sr users_uuids "${XCP_DRIVE_SR_NAME}"; then
      logError "Failed to list VMs using the ${XCP_DRIVE_SR_NAME} SR"
      return 1
    fi
    for res in "${users_uuids[@]}"; do
      # Make sure the VM is halted
      if ! xe_vm_shutdown_by_id "" "${res}"; then
        logError "Failed to shutdown VM ${res}"
        return 1
      fi
    done
  fi

  # Make sure the SR is unplugged
  if ! xe_stor_unplug "${XCP_DRIVE_SR_NAME}"; then
    logError "Failed to unplug the ${XCP_DRIVE_SR_NAME} SR"
    return 1
  fi
}

# Identify disks and store that information
nas_identify_disks() {
  local nas_config_file config_dirty

  # Load hardware configuration
  if ! config_load "${NAS_ROOT}/data/hardware.env"; then
    logError "Failed to load hardware configuration"
    return 1
  fi

  if [[ -z "${DRIVE_MAX}" ]]; then
    logError "DRIVE_MAX is not set"
    return 1
  elif [[ -z "${DRIVE_CONTROLLERS}" ]]; then
    logError "DRIVE_CONTROLLERS is not set"
    return 1
  elif [[ -z "${CONFIG_DIR}" ]]; then
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
    logTrace "Checking disk ${disk}"
    if [[ "${disk}" == "sd"* ]]; then
      : # Ok
    elif [[ "${disk}" == "nvme"* ]]; then
      : # Ok
    else
      logTrace "Skipping disk ${disk}"
      continue
    fi

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
  if [[ ${#candidate_disks[@]} -lt ${DRIVE_MAX} ]]; then
    logError "Expected to find 6 disks at most, we found ${#candidate_disks[@]}."
    return 1
  fi

  # Identify the disks
  local i disk_count
  local -a c_count
  local var_ctrl_prefix var_disk_ctrl var_disk_cnt
  local var_disk_name var_disk_path var_disk_sn var_disk_wwn
  local new_disk_name new_disk_path new_disk_sn new_disk_wwn
  for i in $(seq 1 "${DRIVE_CONTROLLERS}"); do
    declare -A controller_"${i}"
    c_count[i]=0
  done
  for i in $(seq 1 "${DRIVE_MAX}"); do
    declare -A disk_"${i}"
  done

  local d_path d_sn d_wwn ata ata_lowest d_lowest
  disk_count=0
  for disk in "${candidate_disks[@]}"; do
    if ! disk_get_info d_path d_sn d_wwn "${disk}"; then
      logError "Failed to get info for ${disk}"
      return 1
    fi
    for i in $(seq 1 "${DRIVE_CONTROLLERS}"); do
      var_ctrl_prefix="DRIVE_CONTROLLER${i}_PREFIX"
      if [[ "${d_path}" == "${!var_ctrl_prefix}"* ]]; then
        disk_count=$((disk_count + 1))
        c_count[i]=$((c_count[i] + 1))
        var_disk_name="Disk${c_count[${i}]}"
        var_disk_path="Disk${c_count[${i}]}_PATH"
        var_disk_sn="Disk${c_count[${i}]}_SN"
        var_disk_wwn="Disk${c_count[${i}]}_WWN"
        eval "controller_${i}[\"${var_disk_name}\"]=\"${disk}\""
        eval "controller_${i}[\"${var_disk_path}\"]=\"${d_path}\""
        eval "controller_${i}[\"${var_disk_sn}\"]=\"${d_sn}\""
        eval "controller_${i}[\"${var_disk_wwn}\"]=\"${d_wwn}\""
      fi
    done
  done

  if [[ ${disk_count} -ne ${DRIVE_MAX} ]]; then
    logWarn "Expected to find ${DRIVE_MAX} disks, we found ${disk_count}."
  fi

  # For each disk, look at the controller we expect to find it on
  local var_controller
  for i in $(seq 1 "${DRIVE_MAX}"); do
    logTrace "Searching for Drive ${i}"
    var_disk_ctrl="DRIVE${i}_CTRL"
    var_disk_ctrl="${!var_disk_ctrl}"
    var_disk_cnt="${c_count[${var_disk_ctrl}]}"
    # For each drive counted on the controller
    d_lowest=0
    ata_lowest=""
    for j in $(seq 1 "${var_disk_cnt}"); do
      var_controller="controller_${var_disk_ctrl}"
      var_disk_name="${var_controller}[\"Disk${j}\"]"
      var_disk_path="${var_controller}[\"Disk${j}_PATH\"]"
      logTrace "Checking detection ${j} on controller ${var_disk_ctrl}: ${!var_disk_name} @ ${!var_disk_path}"
      if [[ -z "${!var_disk_name}" ]]; then
        logTrace "Skipping Disk ${j} on controller ${var_disk_ctrl}"
        continue
      fi
      ata=$(echo "${!var_disk_path}" | awk -F'/' '{for (i=1; i<=NF; i++) if ($i ~ /ata/) {print $i; exit}}')
      if [[ -z "${ata_lowest}" ]]; then
        ata_lowest="${ata}"
        d_lowest="${j}"
      elif [[ "${ata}" < "${ata_lowest}" ]]; then
        ata_lowest="${ata}"
        d_lowest="${j}"
      fi
    done
    if [[ ${d_lowest} -eq 0 ]]; then
      logWarn "Disk ${i} does not fit with any detections on controller ${var_disk_ctrl}"
    else
      logTrace "Disk ${i} is detection ${d_lowest} (${ata_lowest} on controller ${var_disk_ctrl})"
      var_controller="controller_${var_disk_ctrl}"
      var_disk_name="${var_controller}[\"Disk${d_lowest}\"]"
      var_disk_path="${var_controller}[\"Disk${d_lowest}_PATH\"]"
      var_disk_sn="${var_controller}[\"Disk${d_lowest}_SN\"]"
      var_disk_wwn="${var_controller}[\"Disk${d_lowest}_WWN\"]"
      eval "disk_${i}[\"Name\"]=\"${!var_disk_name}\""
      eval "disk_${i}[\"Path\"]=\"${!var_disk_path}\""
      eval "disk_${i}[\"SN\"]=\"${!var_disk_sn}\""
      eval "disk_${i}[\"WWN\"]=\"${!var_disk_wwn}\""

      # Erase name, so it doesn't get selected a second time
      eval "${var_disk_name}=\"\""
    fi
  done

  # Update configuration
  local log_output res
  res=0
  for i in $(seq 1 "${DRIVE_MAX}"); do
    var_disk_name="D${i}_DEV"
    var_disk_path="D${i}_PATH"
    var_disk_sn="D${i}_SN"
    var_disk_wwn="D${i}_WWN"
    new_disk_name="disk_${i}[\"Name\"]"
    new_disk_path="disk_${i}[\"Path\"]"
    new_disk_sn="disk_${i}[\"SN\"]"
    new_disk_wwn="disk_${i}[\"WWN\"]"
    if [[ -z "${log_output}" ]]; then
      log_output="Disk ${i}"
    else
      log_output+="\n\nDisk ${i}"
    fi
    if [[ -z "${!new_disk_name}" ]]; then
      logWarn "Disk ${i} not detected"
      if [[ -n "${!var_disk_name}" ]]; then
        log_output+=": Disappeared"
        logTrace "Removing Disk ${i} from configuration"
        config_save "${nas_config_file}" "${var_disk_name}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_path}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_sn}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_wwn}" "" || res=1
        config_dirty=1
      else
        log_output+=": Not present"
        config_save "${nas_config_file}" "${var_disk_name}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_path}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_sn}" "" || res=1
        config_save "${nas_config_file}" "${var_disk_wwn}" "" || res=1
      fi
    else
      logTrace "Disk ${i} detected"
      if [[ -z "${!var_disk_name}" ]]; then
        log_output+=": New"
        log_output+="\n  Name : ${!new_disk_name}"
        log_output+="\n  Path : ${!new_disk_path}"
        log_output+="\n  SN   : ${!new_disk_sn}"
        log_output+="\n  WWN  : ${!new_disk_wwn}"
        logTrace "Adding Disk ${i} name to configuration"
        config_save "${nas_config_file}" "${var_disk_name}" "${!new_disk_name}" || res=1
        config_save "${nas_config_file}" "${var_disk_path}" "${!new_disk_path}" || res=1
        config_save "${nas_config_file}" "${var_disk_sn}" "${!new_disk_sn}" || res=1
        config_save "${nas_config_file}" "${var_disk_wwn}" "${!new_disk_wwn}" || res=1
        config_dirty=1
      else
        if [[ "${!var_disk_name}" != "${!new_disk_name}" ]]; then
          log_output+=": Exchanged"
          log_output+="\n  Name : ${!var_disk_name} -> ${!new_disk_name}"
          log_output+="\n  Path : ${!new_disk_path}"
          log_output+="\n  SN   : ${!new_disk_sn}"
          log_output+="\n  WWN  : ${!new_disk_wwn}"
          logTrace "Updating Disk ${i} name"
          config_save "${nas_config_file}" "${var_disk_name}" "${!new_disk_name}" || res=1
          config_save "${nas_config_file}" "${var_disk_path}" "${!new_disk_path}" || res=1
          config_save "${nas_config_file}" "${var_disk_sn}" "${!new_disk_sn}" || res=1
          config_save "${nas_config_file}" "${var_disk_wwn}" "${!new_disk_wwn}" || res=1
          config_dirty=1
        elif [[ "${!var_disk_path}" != "${!new_disk_path}" ]] ||
          [[ "${!var_disk_sn}" != "${!new_disk_sn}" ]] ||
          [[ "${!var_disk_wwn}" != "${!new_disk_wwn}" ]]; then
          log_output+=": Updated"
          if [[ "${!var_disk_path}" != "${!new_disk_path}" ]]; then
            log_output+="\n  Path : ${!var_disk_path} -> ${!new_disk_path}"
            config_save "${nas_config_file}" "${var_disk_path}" "${!new_disk_path}" || res=1
            config_dirty=1
          else
            log_output+="\n  Path : ${!var_disk_path}"
          fi
          if [[ "${!var_disk_sn}" != "${!new_disk_sn}" ]]; then
            log_output+="\n  SN   : ${!var_disk_sn} -> ${!new_disk_sn}"
            config_save "${nas_config_file}" "${var_disk_sn}" "${!new_disk_sn}" || res=1
            config_dirty=1
          else
            log_output+="\n  SN   : ${!var_disk_sn}"
          fi
          if [[ "${!var_disk_wwn}" != "${!new_disk_wwn}" ]]; then
            log_output+="\n  WWN  : ${!var_disk_wwn} -> ${!new_disk_wwn}"
            config_save "${nas_config_file}" "${var_disk_wwn}" "${!new_disk_wwn}" || res=1
            config_dirty=1
          else
            log_output+="\n  WWN  : ${!var_disk_wwn}"
          fi
        else
          log_output+=":"
          log_output+="\n  Path : ${!var_disk_path}"
          log_output+="\n  SN   : ${!var_disk_sn}"
          log_output+="\n  WWN  : ${!var_disk_wwn}"
        fi
      fi
    fi
  done

  logInfo "\nWe have the following drive configuration:\n${log_output}"

  if [[ "${res}" -ne 0 ]]; then
    logError "Failed to update NAS configuration"
    return 1
  fi

  if [[ ${config_dirty} -eq 1 ]]; then
    logInfo "NAS configuration updated"
    if ! config_load "${nas_config_file}"; then
      logError "Failed to reload NAS configuration"
      return 1
    fi
  else
    logInfo "NAS configuration unchanged"
  fi
}

nas_storage_update() {
  local needs_update folder_nas
  needs_update=0

  if [[ -z "${XCP_DRIVE_SR_NAME}" ]]; then
    logError "XCP_DRIVE_SR_NAME is not set"
    return 1
  fi
  folder_nas="${CONFIG_DIR}/${XCP_DRIVE_SR_NAME}"

  if [[ -d "${folder_nas}" ]]; then
    logInfo "NAS disk folder already exists"
  else
    logInfo "Creating NAS disk folder"
    if ! mkdir -p "${folder_nas}"; then
      logError "Failed to create NAS storage folder"
      return 1
    fi
    needs_update=1
  fi

  local -a nas_files
  sh_exec nas_files ls -1 "${folder_nas}"
  readarray -t nas_files <<<"${nas_files[@]}"
  logTrace "Found NAS files: ${nas_files[*]}"
  local disk link cur_dev var_dev_name
  for disk in $(seq "${DRIVE_MAX}"); do
    var_dev_name="D${disk}_DEV"
    if [[ -n "${!var_dev_name}" ]]; then
      link="${folder_nas}/${!var_dev_name}"
      if [[ -L "${link}" ]]; then
        sh_exec cur_dev readlink -f "${link}"
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
      # Remove from the list
      nas_files=("${nas_files[@]/${!var_dev_name}/}")
    fi
  done

  # This is on purpose to remove empty elements
  # shellcheck disable=SC2206
  nas_files=(${nas_files[@]})

  # Are there any files remaining?
  if [[ ${#nas_files[@]} -gt 0 ]]; then
    logWarn "Found ${#nas_files[@]} extra files in ${XCP_DRIVE_SR_NAME} storage folder: \"${nas_files[*]}\""
    needs_update=1
  fi

  local res
  if [[ ${needs_update} -eq 1 ]]; then
    # Make sure it's unmounted first, before modifying it
    if ! nas_storage_unmount; then
      logError "Failed to unmount ${XCP_DRIVE_SR_NAME} storage first"
      return 1
    fi

    # Delete all files in the folder
    if ! rm -rf "${folder_nas:?}"/*; then
      logError "Failed to clean up ${XCP_DRIVE_SR_NAME} storage folder"
      return 1
    fi

    # Create all the simlinks
    for disk in in $(seq "${DRIVE_MAX}"); do
      var_dev_name="D${disk}_DEV"
      if [[ -n "${!var_dev_name}" ]]; then
        if ! ln -s "/dev/${!var_dev_name}" "${folder_nas}/${!var_dev_name}"; then
          logError "Failed to create link for Disk ${disk}"
          return 1
        fi
      fi
    done
  fi

  # Check if the SR exists
  xe_stor_uuid_by_name dummy "${XCP_DRIVE_SR_NAME}"
  res=$?
  if [[ ${res} -eq 1 ]]; then
    logError "Failed to check the existence of the ${XCP_DRIVE_SR_NAME} SR"
    return 1
  fi

  if [[ ${res} -eq 2 ]]; then
    # Create the NAS SR
    if ! xe_stor_create_udev res "${XCP_DRIVE_SR_NAME}" "${folder_nas}"; then
      logError "Failed to create the ${XCP_DRIVE_SR_NAME} SR"
      return 1
    fi
  else
    # Plug the SR back in
    if ! xe_stor_plug "${XCP_DRIVE_SR_NAME}"; then
      logError "Failed to plug the ${XCP_DRIVE_SR_NAME} SR"
      return 1
    fi
  fi

  return 0
}

drive_test() {
  nas_identify_disks
  return $?
}

# Variables loaded externally

# Constants

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
