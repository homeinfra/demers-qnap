#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script installs drivers and configures the AQ113C device (10 GBe NIC)

if [[ -z ${GUARD_QN_AQ113C_SH} ]]; then
  GUARD_QN_AQ113C_SH=1
else
  return
fi

# Install AQ113C drivers
aq113c_install() {
  # Begin by downloading it.
  # We will need it at least to figured out the package name.
  local dir
  if ! aq113c_download dir; then
    logError "Failed to get the driver"
    return 1
  fi

  if ! pushd "${dir}" &>/dev/null; then
    logError "Failed to change directory to ${dir}"
    return 1
  fi

  local $res
  # Find rpm file
  local rpm_file
  rpm_file=$(find . -maxdepth 1 -type f -name "*.rpm")
  if [[ -n "${rpm_file}" ]]; then
    logInfo "Found RPM file: ${rpm_file}"

    # Check if already installed
    local package_name
    package_name=$(rpm -qp --queryformat '%{NAME}' "${rpm_file}")
    if rpm -q "${package_name}" > /dev/null 2>&1; then
      res=0
    else
      # First, make sure the dependencies are installed
      if ! pkg_install "kernel-devel"; then
        logError "Failed to install kernel module devel"
        res=1
      else
        # Install the package
        if ! sudo yum install -y "${rpm_file}"; then
          logError "Failed to install RPM file"
          res=1
        else
          logInfo "Successfully installed AQ113C driver"
          res=0
        fi
      fi
    fi
  else
    logError "Failed to find RPM file"
    res=1
  fi

  popd &>/dev/null
  return 0
}

# Download AQ113C drivers
#
# Parameters:
#   $1[out]: path to the downloaded archive
# Returns:
#   0: Success
#   1: Failure
aq113c_download() {
  local _path="$1"
  local archive="$(basename ${AQ_URL})"
  local location
  local workspace

  if [[ -z "${BIN_DIR}" ]]; then
    logError "BIN_DIR is not set"
    return 1
  fi
  if [[ -z "${DOWNLOAD_DIR}" ]]; then
    logError "DOWNLOAD_DIR is not set"
    return 1
  fi
  location="${DOWNLOAD_DIR}/${archive}"

  # Check if we already have the driver
  if [[ -d "${BIN_DIR}" ]]; then
    workspace=$(find "${BIN_DIR}" -maxdepth 1 -type d -regex ".*Marvell.*${AQ_VERSION}.*")
    if [[ -n "${workspace}" ]]; then
      logInfo "Found existing workspace: ${workspace}"
      eval "$_path='${workspace}'"
      return 0
    fi
  fi

  # Don't download if we don't even have the capability to unzip it after
  if ! command -v unzip &>/dev/null; then
    logError "Unzip is not installed"
    return 1
  fi

  # Download the driver
  if [[ ! -f "${location}" ]]; then
    if ! mkdir -p "$(dirname ${location})"; then
      logError "Failed to create directory for AQ113C archive"
      return 1
    fi
    logTrace "Downloading into ${location} from ${AQ_URL}"
    if ! wget -q -O "${location}" "${AQ_URL}"; then
      logError "Failed to download AQ113C archive"
      return 1
    fi
  fi
  # Unzip the driver
  if ! unzip -q -o "${location}" -d "${BIN_DIR}"; then
    logError "Failed to extract AQ113C driver"
    return 1
  fi

  # Look in the extracted location
  workspace=$(find "${BIN_DIR}" -maxdepth 1 -type d -regex ".*Marvell.*${AQ_VERSION}.*")
  if [[ -n "${workspace}" ]]; then
    workspace="${workspace}"
    logInfo "Found existing workspace: ${workspace}"
  else
    logError "Failed to find the extracted workspace"
    return 1
  fi
  
  eval "$_path='${workspace}'"
  return 0
}

AQ_VERSION="2.5.6"
AQ_URL="https://www.marvell.com/content/dam/marvell/en/drivers/marvell_linux_${AQ_VERSION}.zip"

###########################
###### Startup logic ######
###########################
AQ_ARGS=("$@")
AQ_CWD=$(pwd)
AQ_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
AQ_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${AQ_SOURCE}" ]]; do # resolve $AQ_SOURCE until the file is no longer a symlink
  AQ_ROOT=$(cd -P "$(dirname "${AQ_SOURCE}")" >/dev/null 2>&1 && pwd)
  AQ_SOURCE=$(readlink "${AQ_SOURCE}")
  [[ ${AQ_SOURCE} != /* ]] && AQ_SOURCE=${AQ_ROOT}/${AQ_SOURCE} # if $AQ_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
AQ_ROOT=$(cd -P "$(dirname "${AQ_SOURCE}")" >/dev/null 2>&1 && pwd)
AQ_ROOT=$(realpath "${AQ_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${AQ_ROOT}/external/setup"
source ${SETUP_REPO_DIR}/src/slf4sh.sh
source ${SETUP_REPO_DIR}/src/git.sh
source ${SETUP_REPO_DIR}/src/pkg.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  LOG_CONSOLE=0 # Make sure logger is not outputting anything else on the console than what we want
  echo "ERROR: This script cannot be executed"
  exit 1
fi
