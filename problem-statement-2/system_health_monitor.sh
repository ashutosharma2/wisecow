#!/usr/bin/env bash
# System health monitor (Problem Statement 2, objective 1).
#
# Checks CPU, memory, disk and processes once, prints one status line per
# check, and appends every alert to a log file. It runs once per call, so
# schedule it with cron; the exit code tells the caller the result.
#
# Linux only: reads /proc.

set -euo pipefail

CPU_MAX=80
MEM_MAX=80
DISK_MAX=90
PROC_MAX=500
LOG_FILE="${HEALTH_LOG:-system_health.log}"
SAMPLE_SECONDS=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Checks CPU, memory, disk and process count once and alerts on anything over
its threshold. Alerts are printed and appended to the log file.

Options:
  -c PERCENT   CPU usage threshold                  (default $CPU_MAX)
  -m PERCENT   memory usage threshold               (default $MEM_MAX)
  -d PERCENT   disk usage threshold, per filesystem (default $DISK_MAX)
  -p COUNT     running process threshold            (default $PROC_MAX)
  -l FILE      log file for alerts                  (default $LOG_FILE, or \$HEALTH_LOG)
  -i SECONDS   CPU sampling interval                (default $SAMPLE_SECONDS)
  -h           show this help

Exit codes: 0 all checks OK, 1 at least one alert, 2 usage error.

Example cron entry (every 5 minutes):
  */5 * * * * /opt/scripts/system_health_monitor.sh -l /var/log/system_health.log
EOF
}

die() { echo "error: $*" >&2; exit 2; }

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

while getopts ":c:m:d:p:l:i:h" opt; do
  case "$opt" in
    c) CPU_MAX="$OPTARG" ;;
    m) MEM_MAX="$OPTARG" ;;
    d) DISK_MAX="$OPTARG" ;;
    p) PROC_MAX="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    i) SAMPLE_SECONDS="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) usage >&2; die "option -$OPTARG needs a value" ;;
    *) usage >&2; die "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || die "unexpected argument: $1"

for value in "$CPU_MAX" "$MEM_MAX" "$DISK_MAX" "$PROC_MAX" "$SAMPLE_SECONDS"; do
  is_number "$value" || die "thresholds and interval must be whole numbers, got '$value'"
done
[ -r /proc/stat ] && [ -r /proc/meminfo ] || die "needs Linux (/proc/stat and /proc/meminfo)"
touch "$LOG_FILE" 2>/dev/null || die "can't write to log file $LOG_FILE"

HOST="${HOSTNAME:-$(uname -n)}"
alerts=0

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# report NAME VALUE MAX UNIT [DETAIL...]
# Prints a status line; on an alert, also appends it (and any detail lines)
# to the log file.
report() {
  local name="$1" value="$2" max="$3" unit="$4" line
  shift 4
  if (( value > max )); then
    alerts=$((alerts + 1))
    printf 'ALERT  %-22s %6s%s  (threshold %s%s)\n' "$name" "$value" "$unit" "$max" "$unit"
    {
      printf '%s %s ALERT %s %s%s > %s%s\n' "$(timestamp)" "$HOST" "$name" "$value" "$unit" "$max" "$unit"
      for line in "$@"; do printf '    %s\n' "$line"; done
    } >> "$LOG_FILE"
  else
    printf 'OK     %-22s %6s%s  (threshold %s%s)\n' "$name" "$value" "$unit" "$max" "$unit"
  fi
}

# --- CPU ---------------------------------------------------------------
# /proc/stat holds CPU time since boot, so one read is only an average since
# boot. Usage "now" is the busy share of the time that passed between two reads.
read_cpu() {
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  echo "$((idle + iowait)) $((user + nice + system + idle + iowait + irq + softirq + steal))"
}
read -r idle1 total1 < <(read_cpu)
sleep "$SAMPLE_SECONDS"
read -r idle2 total2 < <(read_cpu)
elapsed=$((total2 - total1))
idle=$((idle2 - idle1))
cpu_pct=0
(( elapsed > 0 )) && cpu_pct=$(( (100 * (elapsed - idle) + elapsed / 2) / elapsed ))

# --- Memory ------------------------------------------------------------
# MemAvailable counts cache the kernel can reclaim; MemFree doesn't, so it
# would overstate usage.
mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
mem_pct=$(( (100 * (mem_total - mem_avail) + mem_total / 2) / mem_total ))

# --- Processes ---------------------------------------------------------
shopt -s nullglob
pids=(/proc/[0-9]*/)
shopt -u nullglob
proc_count=${#pids[@]}
top_procs=()
if command -v ps >/dev/null 2>&1; then
  # Leave out this pipeline's own ps/head, which report meaningless CPU.
  while IFS= read -r line; do top_procs+=("$line"); done \
    < <(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu \
          | awk 'NR == 1 || ($NF != "ps" && $NF != "head")' | head -n 6)
else
  top_procs=("(install procps for the top-5 list)")
fi

# --- Report ------------------------------------------------------------
echo "System health on $HOST at $(timestamp)"
report "cpu" "$cpu_pct" "$CPU_MAX" "%"
report "memory" "$mem_pct" "$MEM_MAX" "%" \
  "used $(( (mem_total - mem_avail) / 1024 )) MiB of $(( mem_total / 1024 )) MiB"

# Disk: every local filesystem except in-memory ones, one line per device.
# Single files bind-mounted into containers (e.g. /etc/hosts) are skipped.
while read -r used_pct mount; do
  [ -d "$mount" ] || continue
  report "disk $mount" "$used_pct" "$DISK_MAX" "%"
done < <(df -P -l -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null \
           | awk 'NR > 1 && !seen[$1]++ {
                    sub(/%$/, "", $5); mnt = $6
                    for (i = 7; i <= NF; i++) mnt = mnt " " $i
                    print $5, mnt }')

report "processes" "$proc_count" "$PROC_MAX" "" "top processes by CPU:" "${top_procs[@]}"

if (( alerts > 0 )); then
  echo "$alerts alert(s) written to $LOG_FILE"
  exit 1
fi
echo "All checks OK"
