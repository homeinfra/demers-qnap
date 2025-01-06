# shellcheck shell=bash
# SPDX-License-Identifier: MIT
#
# This script installs drivers and configures the AQ113C device (10 GBe NIC)

if [[ -z ${GUARD_QN_AQ113C_SH} ]]; then
  GUARD_QN_AQ113C_SH=1
else
  return 0
fi

# Install AQ113C drivers
aq113c_install() {

  # Check if we have the correct version of the driver
  if ! modinfo "${AQ_KO_NAME}" &>/dev/null; then
    logWarn "AQ113C driver not found"
  else
    AQ_PRESENT=1
    logInfo "AQ113C driver already installed. Checking version..."
    local version
    version=$(modinfo "${AQ_KO_NAME}" | grep "^version:" | awk '{print $2}' || true)
    if [[ "${version}" == "${AQ_VERSION}"* ]]; then
      logInfo "AQ113C driver is up to date"
      return 0
    else
      logWarn "AQ113C driver is out of date. Expected version ${AQ_VERSION}, found ${version}"
    fi
  fi

  # If we reach here, the driver needs to be installed
  local dir
  if ! aq113c_download dir; then
    logError "Failed to get the driver"
    return 1
  fi

  if ! pushd "${dir}" &>/dev/null; then
    logError "Failed to change directory to ${dir}"
    return 1
  fi

  local src_dir="${BIN_DIR}/aq113c_src_${AQ_VERSION}"
  local src_arch
  local res=0
  src_arch=$(find . -maxdepth 1 -type f -name "*.tar.gz")
  if [[ -z "${src_arch}" ]]; then
    logError "Failed to find source archive"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! mkdir -p "${src_dir}"; then
    logError "Failed to create source directory"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! tar -xzf "${src_arch}" -C "${src_dir}"; then
    logError "Failed to extract source files"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! pushd "${src_dir}/Linux" &>/dev/null; then
    logError "Failed to change directory to ${dir}"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! pkg_install kernel-devel; then
    logError "Could not install requirements"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! make; then
    logError "Failed to build AQ113C driver"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && [[ "${AQ_PRESENT}" -eq 1 ]]; then
    logInfo "Unloading existing driver"
    if ! rmmod "${AQ_KO_NAME}"; then
      logError "Failed to unload existing driver"
      res=1
    fi
  fi
  if [[ ${res} -eq 0 ]] && ! make load; then
    logError "Failed to load driver"
    res=1
  fi
  if [[ ${res} -eq 0 ]] && ! make install; then
    logError "Failed to install driver"
    res=1
  elif [[ ${res} -eq 0 ]]; then
    logInfo "Successfully installed AQ113C driver"
    res=0
  fi

  popd &>/dev/null || true
  popd &>/dev/null || true

  # shellcheck disable=SC2248
  return ${res}
}

# Download AQ113C drivers
#
# Parameters:
#   $1[out]: path to the downloaded archive
# Returns:
#   0: Success
#   1: Failure
aq113c_download() {
  local _path="${1}"
  local archive
  local location
  local workspace

  archive="$(basename "${AQ_URL}")"

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
      eval "${_path}='${workspace}'"
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
    if ! mkdir -p "$(dirname "${location}")"; then
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
    logInfo "Found existing workspace: ${workspace}"
  else
    logError "Failed to find the extracted workspace"
    return 1
  fi

  eval "${_path}='${workspace}'"
  return 0
}

AQ_VERSION="2.5.12"
AQ_URL="https://www.marvell.com/content/dam/marvell/en/drivers/07-18-24_Marvell_Linux_${AQ_VERSION}.zip"
AQ_KO_NAME="atlantic"

###########################
###### Startup logic ######
###########################

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

# Determine BPKG's global prefix
if [[ -z "${PREFIX}" ]]; then
  if [[ $(id -u || true) -eq 0 ]]; then
    PREFIX="/usr/local"
  else
    PREFIX="${HOME}/.local"
  fi
fi

# Import dependencies
SETUP_REPO_DIR="${AQ_ROOT}/external/setup"
# shellcheck disable=SC1091
if ! source "${PREFIX}/lib/slf4.sh"; then
  echo "Failed to import slf4.sh"
  exit 1
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/git.sh"; then
  logFatal "Failed to import git.sh"
fi
# shellcheck disable=SC1091
if ! source "${SETUP_REPO_DIR}/src/pkg.sh"; then
  logFatal "Failed to import pkg.sh"
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
