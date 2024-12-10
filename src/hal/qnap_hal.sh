#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# This script is used to initialize the Super IO Chip on QNAP devices
# Once initialized, reading and writing directly to the I/O ports is possible.
# Thus, giving access to front panel buttons and LEDs.
# A secondary use, is the buzzer API.

# This uses the original HAL from QNAP, extracted from the original QTS software
# as documented here: https://github.com/davidedg/QNap-TS-470-Pro-USB-Copy-Button-and-Leds
#
# Basically, you need to run the following command on QTS to build the same archive as the
# one stored in /data.
# Please note, this is only tested with QTS 5.1.6.2722. This is already slightly different
# from the example I was following from davidedg. I've had to pull in more files into the
# TAR to make it work.
# ```
#  cd / && tar czf /share/Public/qts-hal.tar.gz \
#   sbin/{daemon_mgr,da_util,hal_app,hal_daemon,hal_util,mpath_util,nasutil,get_ccode} \
#   bin/{sh,bash,busybox,date,echo,grep,ps} \
#   etc/{hal.conf,hal_util*.conf,model*.conf} \
#   dev/null \
#   lib64 \
#   lib/libuLinux_{hal,ini}.so \
#   lib/{ld-2*,ld-linux-*,libc,libc-*,libcrypt,libcrypt-*,libdl,libdl-*,libiconv,libjson,libm,libm-*,libncurses,libpthread,librt,librt-*,libssl,libz,mpath_lib}.so* \
#   usr/lib/libuLinux_{NAS,PDC,Storage,Util,cgi,config,naslog,qha,qlicense,quota,target}.so* \
#   usr/lib/{libcrypto,libsqlite3,libxml2}.so* \
#   --no-recursion tmp var
# ```
# This is also inspired by information that can be found here:
# https://github.com/guedou/TS-453Be/blob/master/doc/fan_control.md#running-qnap-in-a-chroot

qnap_hal_dependencies() {
  if ! pkg_install "python3" "python3-pip" "python3-devel"; then
    logError "Failed to install python3"
    return 1
  fi

  if ! pip_install "python-daemon==2.3.2" "portio==0.6.2"; then
    logError "Failed to install required python modules"
    return 1
  fi

  if [[ -z "${BIN_DIR}" ]]; then
    logError "BIN_DIR is not set"
    return 1
  fi
}

qnap_hal_install() {
  if ! qnap_hal_dependencies; then
    logError "Failed to install dependencies"
    return 1
  fi

  if [[ -z "${QN_ID}" ]]; then
    logError "QN_ID is not set"
    return 1
  fi

  local install_root="${BIN_DIR}/hal"
  local installer="${QN_ROOT}/data/hal_${QN_ID}.tar.gz"

  if [[ ! -d "${install_root}" ]] || [[ -z "$( ls -A "${install_root}" )" ]] ; then
    logTrace "Installing HAL for ${QN_ID}"

    if [[ ! -f "${installer}" ]]; then
      logError "Installer not found: ${installer}"
      return 1
    fi

    if ! mkdir -p "${install_root}"; then
      logError "Failed to create installation directory: ${install_root}"
      return 1
    fi

    if ! tar xvf "${installer}" -C "${install_root}"; then
      logError "Failed to extract installer: ${installer}"
      return 1
    fi
  else
    logInfo "HAL for ${QN_ID} is already installed"
  fi

  local res
  if ! qnap_hal_init; then
    logError "Failed to initialize HAL"
    res=1
  fi

  # Install symbolic links for qnap_hal.sh and qhal.py
  if ! ln -sf "${QN_ROOT}/src/hal/qnap_hal.sh" "${HOME}/bin/qnap_hal"; then
    logError "Failed to create symbolic link for qnap_hal.sh"
    return 1
  fi
  if ! ln -sf "${QN_ROOT}/src/hal/qhal.py" "${HOME}/bin/qhal"; then
    logError "Failed to create symbolic link for qhal.py"
    return 1
  fi

  return $res
}

qnap_hal_init() {
  local ret_value=0
  local install_root="${BIN_DIR}/hal"
  local cmd=("hal_daemon" "-f")

  umount "${install_root}/tmp" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to unmount ${install_root}/tmp"
  fi
  umount "${install_root}/var" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to unmount ${install_root}/var"
  fi

  mount -o size=512K -t tmpfs none "${install_root}/var"
  if [[ $? -ne 0 ]]; then
    logError "Failed to mount ${install_root}/var"
    ret_value=1
  fi
  if [[ $ret_value -eq 0 ]]; then
    mkdir -p "${install_root}"/var/{log,lock}
    if [[ $? -ne 0 ]]; then
      logError "Failed to create ${install_root}/var/{log,lock}"
      ret_value=1
    fi
  fi
  if [[ $ret_value -eq 0 ]]; then
    mount -o size=128K -t tmpfs none "${install_root}/tmp"
    if [[ $? -ne 0 ]]; then
      logError "Failed to mount ${install_root}/tmp"
      ret_value=1
    fi
  fi

  if [[ $ret_value -eq 0 ]]; then
    qnap_hal_invoke ${cmd[@]}
    if [[ $? -eq 0 ]]; then
      sleep 1
      if [[ $? -eq 0 ]]; then
        qnap_hal_invoke ${cmd[@]}
        if [[ $? -eq 0 ]]; then
          sleep 10
          if [[ $? -ne 0 ]]; then
            logError "Failed to wait for hal_daemon to start"
            ret_value=1
          fi
        else
          logError "Failed to start hal_daemon"
          ret_value=1
        fi
      else
        logError "Failed to sleep 1 second the first time"
        ret_value=1
      fi
    else
      logError "Failed to start hal_daemon"
      ret_value=1
    fi
  fi

  # Clean up (best effort)
  kill -9 $(pidof hal_daemon)
  return $ret_value
}

# Wrapper to call a command on the HAL
# We like to call the buzzer, for example:
# ./src/hal/qnap_hal.sh --se_buzzer enc_id=0,mode=9
#
# The different sounds we can make are described here:
# https://sandrotosi.blogspot.com/2021/05/qnap-control-lcd-panel-and-speaker.html
#
# Parameters:
#   $@: The command to call
qnap_hal_invoke() {
  if ! config_load "${QN_ROOT}/data/install.env"; then
    logError "Failed to load configuration"
    return 1
  fi

  local install_root="${BIN_DIR}/hal"
  local res

  logTrace "Executing on the QNAP HAL: $@"
  PATH=$PATH:/bin:/sbin chroot "${install_root}" $@
  res=$?
  logTrace "Exceution completed: $res"

  return $res
}

###########################
###### Startup logic ######
###########################

QN_ARGS=("$@")
QN_CWD=$(pwd)
QN_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
QN_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${QN_SOURCE}" ]]; do # resolve $QN_SOURCE until the file is no longer a symlink
  QN_ROOT=$(cd -P "$(dirname "${QN_SOURCE}")" >/dev/null 2>&1 && pwd)
  QN_SOURCE=$(readlink "${QN_SOURCE}")
  [[ ${QN_SOURCE} != /* ]] && QN_SOURCE=${QN_ROOT}/${QN_SOURCE} # if $QN_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
QN_ROOT=$(cd -P "$(dirname "${QN_SOURCE}")" >/dev/null 2>&1 && pwd)
QN_ROOT=$(realpath "${QN_ROOT}/../..")

# Import dependencies
SETUP_REPO_DIR="${QN_ROOT}/external/setup"
source ${SETUP_REPO_DIR}/src/slf4sh.sh
source ${SETUP_REPO_DIR}/src/env.sh
source ${SETUP_REPO_DIR}/src/pkg.sh
source ${SETUP_REPO_DIR}/src/python.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  qnap_hal_invoke "${QN_ARGS[@]}"
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  qnap_hal_invoke "${QN_ARGS[@]}"
fi
