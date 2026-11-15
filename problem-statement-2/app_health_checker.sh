#!/usr/bin/env bash
# Application health checker (Problem Statement 2, objective 4).
#
# Requests each URL once and decides from the HTTP status code:
#   UP    the server answered with a 2xx status
#   DOWN  any other status (3xx, 4xx, 5xx), a timeout, a refused connection,
#         a DNS failure or a TLS error
# Every result is printed and appended to a log file; the exit code is 0 only
# if every URL is up.
#
# Needs bash 3.2+ and curl (works on Linux and macOS).

set -euo pipefail

TIMEOUT=5
LOG_FILE="${APP_HEALTH_LOG:-app_health.log}"
FOLLOW_REDIRECTS=0
CURL_EXTRA=()
URLS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] URL [URL...]

Checks each URL once. 2xx means UP; anything else, or no answer, means DOWN.

Options:
  -t SECONDS                 give up on a request after this long (default $TIMEOUT)
  -l FILE                    log file (default $LOG_FILE, or \$APP_HEALTH_LOG)
  -L                         follow redirects and judge the final response
  --cacert FILE              trust this CA certificate (e.g. a private cluster CA)
  --resolve HOST:PORT:ADDR   connect to ADDR for HOST:PORT without DNS (repeatable)
  -h, --help                 show this help

Exit codes: 0 all URLs up, 1 at least one down, 2 usage error.

Example:
  $(basename "$0") --cacert wisecow-ca.crt https://wisecow.local/
EOF
}

die() { echo "error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t) [ $# -ge 2 ] || die "-t needs a value"; TIMEOUT="$2"; shift 2 ;;
    -l) [ $# -ge 2 ] || die "-l needs a value"; LOG_FILE="$2"; shift 2 ;;
    -L) FOLLOW_REDIRECTS=1; shift ;;
    --cacert)
      [ $# -ge 2 ] || die "--cacert needs a file"
      [ -r "$2" ] || die "can't read CA file $2"
      CURL_EXTRA+=(--cacert "$2"); shift 2 ;;
    --resolve)
      [ $# -ge 2 ] || die "--resolve needs HOST:PORT:ADDR"
      CURL_EXTRA+=(--resolve "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option $1" ;;
    *) URLS+=("$1"); shift ;;
  esac
done

[ ${#URLS[@]} -gt 0 ] || { usage >&2; die "give at least one URL"; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt 0 ] || die "timeout must be a whole number of seconds"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
touch "$LOG_FILE" 2>/dev/null || die "can't write to log file $LOG_FILE"
[ "$FOLLOW_REDIRECTS" -eq 1 ] && CURL_EXTRA+=(-L --max-redirs 5)

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Turn a curl exit code into a short reason (see `man curl`, EXIT CODES).
reason_for() {
  case "$1" in
    6)  echo "DNS lookup failed" ;;
    7)  echo "connection refused" ;;
    28) echo "no response within ${TIMEOUT}s" ;;
    35) echo "TLS handshake failed" ;;
    52) echo "empty reply from server" ;;
    56) echo "connection reset" ;;
    60) echo "TLS certificate not trusted" ;;
    *)  echo "curl error $1" ;;
  esac
}

down=0
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

for url in "${URLS[@]}"; do
  [[ "$url" =~ ^https?:// ]] || die "not an http(s) URL: $url"

  # ${CURL_EXTRA[@]+...} keeps bash 3.2 happy when the array is empty under set -u.
  rc=0
  result="$(curl -sS -o /dev/null --max-time "$TIMEOUT" \
              -w '%{http_code} %{time_total}' \
              ${CURL_EXTRA[@]+"${CURL_EXTRA[@]}"} "$url" 2>"$err_file")" || rc=$?
  code="${result%% *}"
  ms="$(awk -v s="${result##* }" 'BEGIN { printf "%d", s * 1000 }')"

  if [ "$rc" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    state="UP"; detail="HTTP $code in ${ms} ms"
  elif [ "$rc" -eq 0 ]; then
    state="DOWN"; detail="HTTP $code in ${ms} ms"
  else
    state="DOWN"; detail="$(reason_for "$rc")"
  fi
  [ "$state" = "DOWN" ] && down=$((down + 1))

  printf '%-4s  %s  (%s)\n' "$state" "$url" "$detail"
  printf '%s %s %s (%s)\n' "$(timestamp)" "$state" "$url" "$detail" >> "$LOG_FILE"
done

if [ "$down" -gt 0 ]; then
  echo "$down of ${#URLS[@]} URL(s) down"
  exit 1
fi
echo "All ${#URLS[@]} URL(s) up"
