#!/bin/sh
# Delete radacct detail files and inner-identity linelog files older than
# LOG_RETENTION_DAYS (default 90, see .env). Both are already date-stamped
# per-file (detail-YYYYMMDD, inner-identity-YYYYMMDD.log), so "rotation" here
# is just deleting old files — no in-place log rotation needed.
#
# This script is baked into the image at /usr/local/bin/rotate-logs.sh and
# only needs to run WHERE the log volume is mounted, i.e. inside the
# container. Schedule it from the HOST's crontab:
#
#   30 3 * * * docker exec freeradius rotate-logs.sh >> /var/log/freeradius-rotate.log 2>&1
#
# Usage: rotate-logs.sh [days]   (overrides LOG_RETENTION_DAYS/.env for one run)
set -e

DAYS="${1:-${LOG_RETENTION_DAYS:-90}}"
RADACCT_ROOT="${RADACCT_ROOT:-/var/log/freeradius/radacct}"
LINELOG_ROOT="${LINELOG_ROOT:-/var/log/freeradius/inner-identity}"

echo "$(date -Is) rotate-logs: deleting files older than ${DAYS} days"

if [ -d "${RADACCT_ROOT}" ]; then
	find "${RADACCT_ROOT}" -type f -name 'detail-*' -mtime "+${DAYS}" -print -delete
fi

if [ -d "${LINELOG_ROOT}" ]; then
	find "${LINELOG_ROOT}" -type f -name 'inner-identity-*.log' -mtime "+${DAYS}" -print -delete
fi

echo "$(date -Is) rotate-logs: done"
