#!/usr/bin/env bash
#
# check-cert-renewal.sh
#
# Validates that automatic Let's Encrypt certificate renewal (certbot + cron)
# is healthy on a Linux host, and that the service using the certificate is
# actually serving the current certificate.
#
# Checks performed:
#   1. A certbot "renew" entry exists in cron (/etc/crontab, /etc/cron.d, root crontab)
#   2. certbot ran recently (based on /var/log/letsencrypt modification times)
#   3. The most recent renewal runs reported no errors
#   4. Each certificate's remaining validity (WARN/CRIT thresholds)
#   5. The service is active
#   6. The certificate served over SMTP STARTTLS matches the one on disk
#      (detects "renewed but service not restarted")
#   7. Optional: certbot renew --dry-run (use --dry-run)
#
# Exit codes (Nagios style): 0 = OK, 1 = WARNING, 2 = CRITICAL
#
# Usage:
#   sudo ./check-cert-renewal.sh [--dry-run]
#
# Configuration via environment variables (all optional):
#   CERTBOT_BIN     Path to certbot            (default: /opt/certbot_venv/bin/certbot)
#   SERVICE_NAME    systemd unit to check      (default: opensmtpd)
#   LE_DIR          Let's Encrypt directory    (default: /etc/letsencrypt)
#   LE_LOG_DIR      certbot log directory      (default: /var/log/letsencrypt)
#   WARN_DAYS       Warn if fewer days left    (default: 21)
#   CRIT_DAYS       Critical if fewer days     (default: 7)
#   MAX_RUN_AGE_H   Max hours since last run   (default: 13, cron runs every 12h)
#   SMTP_HOST       Host for the served-cert check (default: 127.0.0.1)
#   SMTP_PORT       Port for STARTTLS check, 0 to skip (default: 25)
#   RUNS_TO_CHECK   How many recent log files to scan for errors (default: 5)

set -u

CERTBOT_BIN="${CERTBOT_BIN:-/opt/certbot_venv/bin/certbot}"
SERVICE_NAME="${SERVICE_NAME:-opensmtpd}"
LE_DIR="${LE_DIR:-/etc/letsencrypt}"
LE_LOG_DIR="${LE_LOG_DIR:-/var/log/letsencrypt}"
WARN_DAYS="${WARN_DAYS:-21}"
CRIT_DAYS="${CRIT_DAYS:-7}"
MAX_RUN_AGE_H="${MAX_RUN_AGE_H:-13}"
SMTP_HOST="${SMTP_HOST:-127.0.0.1}"
SMTP_PORT="${SMTP_PORT:-25}"
RUNS_TO_CHECK="${RUNS_TO_CHECK:-5}"

RUN_DRY=0
[ "${1:-}" = "--dry-run" ] && RUN_DRY=1

WARNINGS=0
CRITICALS=0

if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
fi

ok()   { printf '%s[ OK ]%s %s\n'   "$GREEN"  "$RESET" "$1"; }
warn() { printf '%s[WARN]%s %s\n'   "$YELLOW" "$RESET" "$1"; WARNINGS=$((WARNINGS + 1)); }
crit() { printf '%s[CRIT]%s %s\n'   "$RED"    "$RESET" "$1"; CRITICALS=$((CRITICALS + 1)); }
info() { printf '       %s\n' "$1"; }
title() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 2
fi

printf '%sCertificate auto-renewal check%s  (%s)\n' "$BOLD" "$RESET" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------------------
title "1. Cron entry"
# ---------------------------------------------------------------------------
CRON_MATCH=""
for f in /etc/crontab /etc/cron.d/*; do
  [ -f "$f" ] || continue
  line=$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -E 'certbot.*renew' | head -n 1)
  if [ -n "$line" ]; then CRON_MATCH="$f: $line"; break; fi
done
if [ -z "$CRON_MATCH" ]; then
  line=$(crontab -l -u root 2>/dev/null | grep -v '^[[:space:]]*#' | grep -E 'certbot.*renew' | head -n 1)
  [ -n "$line" ] && CRON_MATCH="root crontab: $line"
fi

if [ -n "$CRON_MATCH" ]; then
  ok "certbot renew is scheduled in cron"
  info "$CRON_MATCH"
  if echo "$CRON_MATCH" | grep -q -- '--deploy-hook'; then
    ok "a --deploy-hook is configured (service restart after renewal)"
  else
    warn "no --deploy-hook found in the cron entry; the service may not pick up renewed certificates"
  fi
else
  crit "no certbot renew entry found in cron"
fi

# ---------------------------------------------------------------------------
title "2. Recent certbot execution"
# ---------------------------------------------------------------------------
if [ -d "$LE_LOG_DIR" ]; then
  RECENT=$(find "$LE_LOG_DIR" -maxdepth 1 -name 'letsencrypt.log*' -mmin "-$((MAX_RUN_AGE_H * 60))" 2>/dev/null | head -n 1)
  LATEST=$(ls -t "$LE_LOG_DIR"/letsencrypt.log* 2>/dev/null | head -n 1)
  if [ -n "$RECENT" ]; then
    ok "certbot ran within the last ${MAX_RUN_AGE_H}h"
  else
    crit "no certbot activity in the last ${MAX_RUN_AGE_H}h (cron not firing?)"
  fi
  [ -n "$LATEST" ] && info "latest log file: $LATEST ($(date -r "$LATEST" '+%Y-%m-%d %H:%M'))"
else
  crit "log directory $LE_LOG_DIR not found"
fi

# ---------------------------------------------------------------------------
title "3. Errors in recent renewal runs"
# ---------------------------------------------------------------------------
if [ -d "$LE_LOG_DIR" ]; then
  RENEW_LOGS=$(grep -l 'Processing /etc/letsencrypt/renewal' $(ls -t "$LE_LOG_DIR"/letsencrypt.log* 2>/dev/null | head -n 40) 2>/dev/null | head -n "$RUNS_TO_CHECK")
  if [ -z "$RENEW_LOGS" ]; then
    warn "no renewal runs found in the most recent logs"
  else
    BAD=0
    for lf in $RENEW_LOGS; do
      if grep -qE 'renewal failures|Failed to renew|ERROR:|Traceback' "$lf" 2>/dev/null \
         && ! grep -q 'no renewal failures' "$lf" 2>/dev/null; then
        BAD=$((BAD + 1))
        info "problem detected in $lf"
      fi
    done
    if [ "$BAD" -eq 0 ]; then
      ok "last $(echo "$RENEW_LOGS" | wc -l) renewal runs finished without failures"
    else
      crit "$BAD of the last $(echo "$RENEW_LOGS" | wc -l) renewal runs reported failures"
    fi
    LASTRUN=$(echo "$RENEW_LOGS" | head -n 1)
    if grep -q 'not yet due for renewal' "$LASTRUN" 2>/dev/null; then
      info "last run: certificate not yet due for renewal (expected until the renewal window)"
    fi
    WINDOW=$(grep -A3 'suggestedWindow' "$LASTRUN" 2>/dev/null | grep -E '"(start|end)"' | tr -d ' ,' | tr '\n' ' ')
    [ -n "$WINDOW" ] && info "ARI suggested renewal window: $WINDOW"
  fi
fi

# ---------------------------------------------------------------------------
title "4. Certificate validity"
# ---------------------------------------------------------------------------
NOW=$(date +%s)
FOUND=0
for dir in "$LE_DIR"/live/*/; do
  [ -f "${dir}cert.pem" ] || continue
  FOUND=1
  name=$(basename "$dir")
  end_str=$(openssl x509 -in "${dir}cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  end_ts=$(date -d "$end_str" +%s 2>/dev/null || echo 0)
  days=$(( (end_ts - NOW) / 86400 ))
  if [ "$end_ts" -eq 0 ]; then
    crit "$name: could not read expiry date"
  elif [ "$days" -lt "$CRIT_DAYS" ]; then
    crit "$name: expires in $days days ($end_str)"
  elif [ "$days" -lt "$WARN_DAYS" ]; then
    warn "$name: expires in $days days ($end_str)"
  else
    ok "$name: valid for $days more days ($end_str)"
  fi
done
[ "$FOUND" -eq 0 ] && crit "no certificates found in $LE_DIR/live"

# ---------------------------------------------------------------------------
title "5. Service status"
# ---------------------------------------------------------------------------
if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "$SERVICE_NAME is active"
  since=$(systemctl show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value 2>/dev/null)
  [ -n "$since" ] && info "active since: $since"
else
  crit "$SERVICE_NAME is not active"
fi

# ---------------------------------------------------------------------------
title "6. Served certificate matches the one on disk"
# ---------------------------------------------------------------------------
if [ "$SMTP_PORT" -eq 0 ]; then
  info "skipped (SMTP_PORT=0)"
elif ! command -v openssl >/dev/null 2>&1; then
  warn "openssl not available, skipping served-certificate check"
else
  for dir in "$LE_DIR"/live/*/; do
    [ -f "${dir}cert.pem" ] || continue
    name=$(basename "$dir")
    disk_fp=$(openssl x509 -in "${dir}cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    served_fp=$(echo | timeout 15 openssl s_client -starttls smtp \
                  -connect "${SMTP_HOST}:${SMTP_PORT}" -servername "$name" 2>/dev/null \
                | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    if [ -z "$served_fp" ]; then
      warn "$name: could not retrieve certificate from ${SMTP_HOST}:${SMTP_PORT} (STARTTLS)"
    elif [ "$served_fp" = "$disk_fp" ]; then
      ok "$name: the service is serving the current certificate"
    else
      crit "$name: served certificate differs from disk (service restart needed?)"
      info "disk:   $disk_fp"
      info "served: $served_fp"
    fi
  done
fi

# ---------------------------------------------------------------------------
if [ "$RUN_DRY" -eq 1 ]; then
  title "7. certbot renew --dry-run"
  if "$CERTBOT_BIN" renew --dry-run >/tmp/certbot-dry-run.$$ 2>&1; then
    ok "dry-run completed successfully"
    info "note: a dry-run validates the ACME flow but does not run deploy hooks"
  else
    crit "dry-run failed, see output below"
    tail -n 25 /tmp/certbot-dry-run.$$ | sed 's/^/       /'
  fi
  rm -f /tmp/certbot-dry-run.$$
fi

# ---------------------------------------------------------------------------
title "Summary"
printf 'Warnings: %s   Critical: %s\n' "$WARNINGS" "$CRITICALS"
if [ "$CRITICALS" -gt 0 ]; then
  printf '%sRESULT: CRITICAL%s\n' "$RED" "$RESET"; exit 2
elif [ "$WARNINGS" -gt 0 ]; then
  printf '%sRESULT: WARNING%s\n' "$YELLOW" "$RESET"; exit 1
else
  printf '%sRESULT: OK%s\n' "$GREEN" "$RESET"; exit 0
fi
