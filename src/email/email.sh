#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# This script configures email notifications on XCP-ng

if [[ -z ${GUARD_QN_EMAIL_SH} ]]; then
  GUARD_QN_EMAIL_SH=1
else
  return
fi

email_install_prerequisites() {
  if ! command -v mail &>/dev/null; then
    logError "mail command not found. We expected to find it by default on XCP-ng"
  fi
  if ! command -v sops &>/dev/null; then
    logError "SOPS is required"
  fi

  return 0
}

email_install() {
  local bin_dir="${EM_ROOT}/bin"
  local config_dir="${bin_dir}/.config"
  local mail_config_src="${EM_ROOT}/data/sendemail.env"
  local mail_config_dst="${config_dir}/sendemail.conf"

  if [[ -f "${mail_config_src}" ]]; then
    logInfo "Mail configuration found"
  else
    logError "Mail configuration not found"
    return 1
  fi

  if mkdir -p "${config_dir}"; then
    logInfo "Created configuration directory"
  else
    logError "Failed to create configuration directory"
    return 1
  fi

  if sops -d --input-type dotenv --output-type dotenv "${mail_config_src}" > "${mail_config_dst}"; then
    logInfo "Successfully decrypted mail configuration"
  else
    logError "Failed to decrypt mail configuration"
    return 1
  fi

  # Load gmail configuration
  local gmail_config="${EM_ROOT}/data/gmail.env"
  if [[ -f "${gmail_config}" ]]; then
    if ! config_load "${gmail_config}"; then
      logError "Failed to load gmail configuration"
      return 1
    fi
    logInfo "Loaded mail configuration"
  else
    logError "gmail configuration not found"
    return 1
  fi

  # Configure ssmtp
  local ssmtp_conf="/etc/ssmtp/ssmtp.conf"
  if config_save "${ssmtp_conf}" "mailhub" "${GMAIL_HUB}"; then
    logInfo "Configured mailhub"
  else
    logError "Failed to configure mailhub"
    return 1
  fi
  if config_save "${ssmtp_conf}" "AuthUser" "${GMAIL_USER}"; then
    logInfo "Configured AuthUser"
  else
    logError "Failed to configure AuthUser"
    return 1
  fi
  if config_save "${ssmtp_conf}" "AuthPass" "${GMAIL_PASS}"; then
    logInfo "Configured AuthPass"
  else
    logError "Failed to configure AuthPass"
    return 1
  fi
  if config_save "${ssmtp_conf}" "UseSTARTTLS" "${GMAIL_USESTARTTLS}"; then
    logInfo "Configured UseSTARTTLS"
  else
    logError "Failed to configure UseSTARTTLS"
    return 1
  fi

  # Configure XCP-ng
  if ! xh_configure_email "${mail_config_dst}"; then
    logError "Failed to configure email"
    return 1
  else
    logInfo "Configured XCP-ng's email notifications"
  fi

  # Install the email test script
  file=$(cat <<EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test sending of an email
# (This file was automatically generated during installation)

# Import email configuration
source "${mail_config_dst}"

SUBJECT="Test email from \${HOSTNAME}"
(
   echo ""
   echo "\${SUBJECT}"
   echo ""
   echo "Arguments: (\$#):"
  for arg in "\$@"; do
      echo "  \${arg}"
   done
   echo ""
   echo "This is simply a test email"
   echo ""
) | \${MAIL_CMD} -s "\${SUBJECT}" -r \${SENDER} \${SYSADMIN}
EOF
  )

  echo "${file}" > "${bin_dir}/email_test.sh"
  chmod +x "${bin_dir}/email_test.sh"
  logInfo "Installed email test script"

  # Install the XCP-ng notification test script
  file=$(cat <<EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test XCP-ng notifications
# (This file was automatically generated during installation)

if ! command -v xe &>/dev/null; then
  echo "XCP-ng not detected"
  exit 1
fi

if ! res=\$(xe host-list name-label=\$(hostname) --minimal); then
  echo "Failed to get host"
  exit 1
elif [[ -z "\${res}" ]]; then
  echo "Host not found"
  exit 1
elif [[ "\${res}" == *","* ]]; then
  echo "Multiple hosts found"
  exit 1
else
  HOST_ID=\${res}
fi

xe message-create name="Test" body="This is a test notification" priority=3 host-uuid=\${HOST_ID}

EOF
  )

  echo "${file}" > "${bin_dir}/notification_test.sh"
  chmod +x "${bin_dir}/notification_test.sh"
  logInfo "Installed notification test script"
}

###########################
###### Startup logic ######
###########################
EM_ARGS=("$@")
EM_CWD=$(pwd)
EM_ME="$(basename "$0")"

# Get directory of this script
# https://stackoverflow.com/a/246128
EM_SOURCE=${BASH_SOURCE[0]}
while [[ -L "${EM_SOURCE}" ]]; do # resolve $EM_SOURCE until the file is no longer a symlink
  EM_ROOT=$(cd -P "$(dirname "${EM_SOURCE}")" >/dev/null 2>&1 && pwd)
  EM_SOURCE=$(readlink "${EM_SOURCE}")
  [[ ${EM_SOURCE} != /* ]] && EM_SOURCE=${EM_ROOT}/${EM_SOURCE} # if $EM_SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
EM_ROOT=$(cd -P "$(dirname "${EM_SOURCE}")" >/dev/null 2>&1 && pwd)
EM_ROOT=$(realpath "${EM_ROOT}/../..")

# Import dependencies
source ${EM_ROOT}/external/setup/src/slf4sh.sh
source ${EM_ROOT}/external/setup/src/config.sh
source ${EM_ROOT}/libs/xenapi/src/xe_host.sh

if [[ -p /dev/stdin ]] && [[ -z ${BASH_SOURCE[0]} ]]; then
  # This script was piped
  echo "ERROR: This script cannot be piped"
  exit 1
elif [[ ${BASH_SOURCE[0]} != "${0}" ]]; then
  # This script was sourced
  :
else
  # This script was executed
  echo "ERROR: This script cannot be executed"
  exit 1
fi
