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
  local mail_config_src="${EM_ROOT}/data/email.env"
  local mail_config_dst="${config_dir}/$(basename "${mail_config_src}")"

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

  # Add include guard to email config
  local file
  file=$(cat <<EOF
# Configuration options for sending emails

if [[ -z "\${GUARD_EMAIL_ENV}" ]]; then
  GUARD_EMAIL_ENV=1
else
  return
fi

$(cat "${mail_config_dst}")
EOF
  )
  echo "${file}" > "${mail_config_dst}"
  if [[ $? -ne 0 ]]; then
    logError "Failed to add include guard to email configuration"
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
  local ssmtp_conf_backp="${ssmtp_conf}.bak"
  if [[ -f "${ssmtp_conf}" ]]; then
    if [[ ! -f "${ssmtp_conf_backp}" ]]; then
      cp "${ssmtp_conf}" "${ssmtp_conf_backp}"
    fi
  else 
    logWarn "ssmtp configuration was not found"
  fi

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
source "${EM_ROOT}/external/setup/src/slf4sh.sh"

SUBJECT="[\$(hostname)] Test email"
MESSAGE=\$(cat <<END

Subject: \${SUBJECT}

Arguments: (\$#):"
\$(for arg in "\$@"; do echo "  \${arg}"; done)

This is simply a test email

END
)

# Logging it
logInfo <<END
Logging test email:

\${MESSAGE}
END

echo "\${MESSAGE}" | \${MAIL_CMD} -s "\${SUBJECT}" -r \${SENDER} \${SYSADMIN}
if [[ \$? -ne 0 ]]; then
  logError "Failed to send test email"
  exit 1
else
  logInfo "Test email sent succesfully"
fi

EOF
  )

  logInfo "Installing email test script"
  echo "${file}" > "${bin_dir}/email_test.sh"
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to install email test script"
  fi
  chmod +x "${bin_dir}/email_test.sh"
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to make email test script executable"
  fi

  # Install the XCP-ng notification test script
  file=$(cat <<EOF
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Test XCP-ng notifications
# (This file was automatically generated during installation)

source "${EM_ROOT}/external/setup/src/slf4sh.sh"

if ! command -v xe &>/dev/null; then
  logError "XCP-ng not detected"
  exit 1
fi

# XCP-ng message levels
LVL_ERROR=1
LVL_WARN=2
LVL_INFO=3
LVL_DEBUG=4
LVL_TRACE=5

if ! res=\$(xe host-list name-label=\$(hostname) --minimal); then
  logError "Failed to get host"
  exit 1
elif [[ -z "\${res}" ]]; then
  logError "Host not found"
  exit 1
elif [[ "\${res}" == *","* ]]; then
  logError "Multiple hosts found"
  exit 1
else
  HOST_ID=\${res}
fi

xe message-create name="Test" body="This is a test notification" priority=\${LVL_INFO} host-uuid=\${HOST_ID}
if [[ \$? -ne 0 ]]; then
  logError "Failed to send notification to XCP-ng"
  exit 1
else
  logInfo "Test notification sent succesfully"
fi

EOF
  )

  logInfo "Installing notification test script"
  echo "${file}" > "${bin_dir}/notification_test.sh"
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to install notification test script"
  fi
  chmod +x "${bin_dir}/notification_test.sh"
  if [[ $? -ne 0 ]]; then
    logWarn "Failed to make notification test script executable"
  fi

  return 0
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
  # echo "ERROR: This script cannot be executed"
  # exit 1
  email_install
fi
