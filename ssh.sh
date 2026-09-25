#!/usr/bin/env bash
#
# monitor_cpu_ssh.sh
# Dual-condition monitoring harness: CPU > 70% AND SSH responsiveness > 3s
#

set -o pipefail

# -----------------------------------------------------------------------------
# Environmental Configuration
# -----------------------------------------------------------------------------
REMOTE_USER="monitoring_agent"
REMOTE_HOST="192.168.10.150"
REMOTE_PORT="22"
SSH_IDENTITY="/etc/ssl/certs/monitoring_ed25519"
TRIGGER_ACTION="/usr/local/bin/script.sh"

CPU_THRESHOLD=70
PROBE_DEADLINE=3

# Non-interactive OpenSSH configuration flags
SSH_BASE_ARGS=(
    -q
    -p "${REMOTE_PORT}"
    -i "${SSH_IDENTITY}"
    -o "BatchMode=yes"
    -o "StrictHostKeyChecking=accept-new"
    -o "UserKnownHostsFile=/dev/null"
    -o "LogLevel=ERROR"
)

log_event() {
    local severity="$1"
    local message="$2"
    printf "[%s] [%s] %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${severity}" "${message}"
}

# -----------------------------------------------------------------------------
# Phase 1: Metric Extraction
# -----------------------------------------------------------------------------
log_event "INFO" "Initiating metric sampling on ${REMOTE_HOST}..."

# Execute vmstat over SSH to sample the non-idle CPU percentage across 1 second
METRIC_QUERY="vmstat 1 2 | tail -n 1 | awk '{print 100 - \$15}'"

RAW_CPU_OUTPUT=$(ssh "${SSH_BASE_ARGS[@]}" \
    -o "ConnectTimeout=5" \
    "${REMOTE_USER}@${REMOTE_HOST}" "${METRIC_QUERY}" 2>/dev/null)
POLL_STATUS=$?

if [[ ${POLL_STATUS} -ne 0 ]] || [[ -z "${RAW_CPU_OUTPUT}" ]]; then
    log_event "NOTICE" "Initial metric extraction failed with status ${POLL_STATUS}. Preconditions unmet; exiting."
    exit 0
fi

# Sanitize output by stripping floating points for integer comparison
CPU_PERCENT=${RAW_CPU_OUTPUT%.*}
log_event "INFO" "Host ${REMOTE_HOST} reported aggregate CPU utilization: ${CPU_PERCENT}%."

if [[ "${CPU_PERCENT}" -le "${CPU_THRESHOLD}" ]]; then
    log_event "INFO" "CPU utilization (${CPU_PERCENT}%) is within acceptable threshold (<= ${CPU_THRESHOLD}%). No action required."
    exit 0
fi

log_event "WARN" "Threshold exceeded: CPU utilization at ${CPU_PERCENT}% (Trigger limit: > ${CPU_THRESHOLD}%)."

# -----------------------------------------------------------------------------
# Phase 2: Responsiveness Verification Probe
# -----------------------------------------------------------------------------
log_event "INFO" "Dispatching responsiveness probe with ${PROBE_DEADLINE}s hard timeout..."

# Execute a zero-overhead binary probe wrapped in GNU coreutils timeout
timeout -k 1s "${PROBE_DEADLINE}s" \
    ssh "${SSH_BASE_ARGS[@]}" \
    -o "ConnectTimeout=${PROBE_DEADLINE}" \
    "${REMOTE_USER}@${REMOTE_HOST}" "true" 2>/dev/null
PROBE_STATUS=$?

# -----------------------------------------------------------------------------
# Compound Condition Evaluation
# -----------------------------------------------------------------------------
if [[ ${PROBE_STATUS} -eq 124 ]]; then
    log_event "ALERT" "Probe deadline expired: ${REMOTE_HOST} failed to respond within ${PROBE_DEADLINE} seconds."
    log_event "EMERGENCY" "Compound condition verified (CPU > ${CPU_THRESHOLD}% AND Latency > ${PROBE_DEADLINE}s)."

    if [[ -x "${TRIGGER_ACTION}" ]]; then
        log_event "EXEC" "Executing trigger script: ${TRIGGER_ACTION}"
        "${TRIGGER_ACTION}" "${REMOTE_HOST}" "${CPU_PERCENT}" "${PROBE_DEADLINE}"
        exit $?
    else
        log_event "CRITICAL" "Trigger script ${TRIGGER_ACTION} does not exist or lacks executable permissions."
        exit 1
    fi
else
    log_event "INFO" "Probe responded within ${PROBE_DEADLINE}s window (Status: ${PROBE_STATUS}). Host retains capacity; no action required."
    exit 0
fi


