#!/usr/bin/env bash
#
# /usr/local/bin/script.sh
# HAProxy Round-Robin Configuration Switcher with Automated Backups & Rollback
#
# State transition:
#   Trigger 1: Backup config 1 -> Deploy /etc/haproxy/profiles/2/haproxy.cfg (State = 2)
#   Trigger 2: Backup config 2 -> Deploy /etc/haproxy/profiles/3/haproxy.cfg (State = 3)
#   Trigger 3: Backup config 3 -> Deploy /etc/haproxy/profiles/4/haproxy.cfg (State = 4)
#   Trigger 4: Backup config 4 -> Deploy /etc/haproxy/profiles/5/haproxy.cfg (State = 5)
#   Trigger 5: Backup config 5 -> Deploy /etc/haproxy/profiles/1/haproxy.cfg (State = 1)
#   Trigger 6+: Loops back to config 2 in round-robin sequence
#

set -euo pipefail


HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
PROFILES_DIR="/etc/haproxy/profiles"
BACKUP_DIR="/etc/haproxy/backups"
STATE_FILE="/etc/haproxy/.current_cfg_state"
LOCK_FILE="/var/run/haproxy_switcher.lock"
LOG_FILE="/var/log/haproxy_failover.log"
TOTAL_CONFIGS=5


mkdir -p "${BACKUP_DIR}" "${PROFILES_DIR}" "$(dirname "${LOG_FILE}")" "$(dirname "${LOCK_FILE}")"


log_message() {
    local severity="$1"
    local message="$2"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf "[%s] [%s] %s\n" "${timestamp}" "${severity}" "${message}" | tee -a "${LOG_FILE}" >&2
}


exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    log_message "WARN" "Another instance of script.sh is actively running. Exiting to avoid collision."
    exit 0
fi


if [[ -f "${STATE_FILE}" ]]; then
    CURRENT_INDEX=$(<"${STATE_FILE}")
    if ! [[ "${CURRENT_INDEX}" =~ ^[1-5]$ ]]; then
        log_message "WARN" "Invalid or corrupted state detected ('${CURRENT_INDEX}'). Resetting index to 1."
        CURRENT_INDEX=1
    fi
else
    CURRENT_INDEX=1
fi

NEXT_INDEX=$(( (CURRENT_INDEX % TOTAL_CONFIGS) + 1 ))
SOURCE_CFG="${PROFILES_DIR}/${NEXT_INDEX}/haproxy.cfg"

log_message "INFO" "Rotation triggered. Active configuration: ${CURRENT_INDEX}. Target next configuration: ${NEXT_INDEX}."


if [[ ! -f "${PROFILES_DIR}/1/haproxy.cfg" ]] && [[ -f "${HAPROXY_CFG}" ]]; then
    mkdir -p "${PROFILES_DIR}/1"
    cp -p "${HAPROXY_CFG}" "${PROFILES_DIR}/1/haproxy.cfg"
    chmod 640 "${PROFILES_DIR}/1/haproxy.cfg"
    log_message "NOTICE" "Captured running baseline config into ${PROFILES_DIR}/1/haproxy.cfg."
fi


if [[ ! -f "${SOURCE_CFG}" ]]; then
    log_message "ERROR" "Candidate configuration file ${SOURCE_CFG} does not exist. Aborting rotation."
    exit 1
fi

if command -v haproxy >/dev/null 2>&1; then
    log_message "INFO" "Verifying syntax of candidate configuration ${SOURCE_CFG}..."
    if ! haproxy -c -q -f "${SOURCE_CFG}"; then
        log_message "CRITICAL" "Syntax validation failed for ${SOURCE_CFG}. Refusing to deploy broken configuration."
        exit 1
    fi
fi


TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_TARGET="${BACKUP_DIR}/haproxy.cfg.bak_${TIMESTAMP}_cfg${CURRENT_INDEX}"

if [[ -f "${HAPROXY_CFG}" ]]; then
    cp -p "${HAPROXY_CFG}" "${BACKUP_TARGET}"
    log_message "INFO" "Backup created: ${BACKUP_TARGET}"
else
    log_message "WARN" "Active file ${HAPROXY_CFG} not found; skipping backup."
fi

cp -f "${SOURCE_CFG}" "${HAPROXY_CFG}"
chmod 644 "${HAPROXY_CFG}"
log_message "INFO" "Applied ${SOURCE_CFG} to ${HAPROXY_CFG}."


rollback_on_failure() {
    log_message "CRITICAL" "HAProxy failed to reload/restart with new config! Initiating immediate rollback..."
    if [[ -f "${BACKUP_TARGET}" ]]; then
        cp -f "${BACKUP_TARGET}" "${HAPROXY_CFG}"
        chmod 644 "${HAPROXY_CFG}"
        if systemctl restart haproxy; then
            log_message "NOTICE" "Rollback successful. Restored previous configuration ${CURRENT_INDEX}."
        else
            log_message "EMERGENCY" "Rollback failed! Manual intervention required to restore HAProxy."
        fi
    fi
    exit 1
}

if systemctl is-active --quiet haproxy; then
    log_message "INFO" "Reloading HAProxy daemon..."
    if ! systemctl reload haproxy; then
        log_message "WARN" "Graceful reload failed. Attempting service restart..."
        if ! systemctl restart haproxy; then
            rollback_on_failure
        fi
    fi
    log_message "INFO" "HAProxy successfully running new configuration."
fi

TEMP_STATE_FILE="${STATE_FILE}.tmp.$$"
echo "${NEXT_INDEX}" > "${TEMP_STATE_FILE}"
mv -f "${TEMP_STATE_FILE}" "${STATE_FILE}"

log_message "SUCCESS" "Rotation complete. Active configuration index updated to ${NEXT_INDEX}."

exit 0