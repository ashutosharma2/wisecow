# Problem Statement 2: two Bash scripts

I picked objective 1 (system health monitoring) and objective 4 (application health checker), both in Bash. Each runs once per call and reports through a log file and its exit code, so cron or a CI step can act on the result. The reasoning is in [ADR-004](../docs/adr/004-health-scripts.md).

| Exit code | `system_health_monitor.sh` | `app_health_checker.sh` |
|---|---|---|
| 0 | every check under its threshold | every URL up |
| 1 | at least one alert | at least one URL down |
| 2 | bad usage, or not Linux | bad usage, or curl missing |

## system_health_monitor.sh

Checks CPU, memory, disk and processes once. Linux only, because it reads `/proc`.

- **CPU:** `/proc/stat` read twice, a second apart. The counters are totals since boot, so the usage "now" is the busy share of the time between the two reads.
- **Memory:** `MemTotal − MemAvailable` from `/proc/meminfo`. `MemFree` would count reclaimable cache as used.
- **Disk:** every local filesystem from `df -P`, skipping in-memory ones (tmpfs) and single files bind-mounted into containers.
- **Processes:** the number of running processes. When it's over the limit, the log entry lists the top 5 by CPU.

```bash
./system_health_monitor.sh                       # defaults: CPU 80%, memory 80%, disk 90%, 500 processes
```

```bash
./system_health_monitor.sh -c 90 -d 85 -l /var/log/system_health.log
```

Every alert goes to the log file (default `system_health.log`, or `$HEALTH_LOG`). To run it every 5 minutes:

```
*/5 * * * * /opt/scripts/system_health_monitor.sh -l /var/log/system_health.log
```

Output in a test container with eight `yes` processes pinning the CPU (the container's bind-mounted folders are left out):

```
System health on fde3dac0cbd5 at 2026-11-15 18:24:41
ALERT  cpu                        98%  (threshold 80%)
OK     memory                     60%  (threshold 80%)
OK     disk /                      6%  (threshold 90%)
OK     processes                  10  (threshold 500)
1 alert(s) written to /tmp/h.log
```

## app_health_checker.sh

Requests each URL once. A 2xx status is **UP**. Anything else is **DOWN**: other status codes (including redirects), timeouts, refused connections, DNS failures and TLS errors. Works on Linux and macOS (bash 3.2+ and curl).

```bash
./app_health_checker.sh https://example.com/
```

```bash
./app_health_checker.sh -t 10 --cacert wisecow-ca.crt https://wisecow.local/ http://wisecow.local/
```

| Option | Meaning |
|---|---|
| `-t SECONDS` | give up after this long (default 5) |
| `-l FILE` | log file (default `app_health.log`, or `$APP_HEALTH_LOG`) |
| `-L` | follow redirects and judge the final response |
| `--cacert FILE` | trust a private CA, such as the wisecow cluster's |
| `--resolve HOST:PORT:ADDR` | reach a host name that has no DNS entry |

Every result, up or down, is logged with a timestamp, so the log is an uptime record. Results from the tests:

```
UP    https://github.com/  (HTTP 200 in 591 ms)
DOWN  http://wisecow.local/  (HTTP 301 in 112 ms)
DOWN  https://wisecow.local/  (TLS certificate not trusted)
DOWN  http://127.0.0.1:8765/missing  (HTTP 404 in 49 ms)
DOWN  http://127.0.0.1:9/  (connection refused)
DOWN  http://127.0.0.1:8767/  (no response within 2s)
DOWN  http://does-not-exist.invalid/  (DNS lookup failed)
```

`http://wisecow.local/` is DOWN by design: it answers with a redirect to HTTPS, not the app. Use `-L` to judge where the redirect lands.

The CI pipeline runs this checker against every deployment: after the smoke test, it checks `https://wisecow.local/` in the kind cluster, verified against the cluster's CA.
