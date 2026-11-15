# ADR-004: Two run-once Bash health scripts that report through a log file and an exit code

- Status: Accepted
- Date: 2026-11-16

## Scenario

Problem Statement 2 asks for two of four operational scripts, in Bash or Python. I chose the **system health monitor** (CPU, memory, disk and processes, with alerts over a threshold) and the **application health checker** (up or down from HTTP status codes). Both are in Bash.

## Obstacle

- **CPU usage isn't a single number you can read.** `/proc/stat` holds CPU time since boot, so one read gives the average since boot, not the load right now.
- **"Free" memory is misleading.** `MemFree` leaves out cache the kernel can hand back at once, so it makes a healthy machine look full.
- **A script that loops never reports.** If the monitor runs forever, cron and CI can't use an exit code to tell healthy from unhealthy.
- **"Up" needs an exact definition.** A redirect, a 404, a refused connection, a request that hangs and an untrusted certificate all have to land on one side or the other. Wisecow's own `http://` URL answers with a 301 redirect.
- **The checker has to work against wisecow's private CA** and a host name (`wisecow.local`) that has no DNS entry.
- **macOS has no `/proc`**, and its bash is 3.2.

## Action

1. **Both scripts run once per call** and report the same way: one line per check on the console, a timestamped entry in a log file, and an exit code of 0 (healthy), 1 (alert or down) or 2 (bad usage). Cron or a CI step decides how often to run them and what to do with the result.
2. **Monitor:**
   - CPU from `/proc/stat`, read twice one second apart; usage is the busy share of the time between the reads.
   - Memory as `MemTotal − MemAvailable` from `/proc/meminfo`.
   - Disk per local filesystem from `df -P`, skipping in-memory filesystems and single files bind-mounted into containers.
   - Process count from `/proc`; when it's over the limit, the log lists the top 5 by CPU.
   - Defaults CPU 80%, memory 80%, disk 90%, 500 processes, each changeable with a flag. Only alerts are logged.
3. **Checker:**
   - **2xx is UP. Everything else is DOWN**: any other status code (redirects included), a timeout (5 s by default), a refused connection, a DNS failure or a TLS error. Each DOWN says why.
   - Certificates are always verified. `--cacert` trusts a private CA; `--resolve` reaches a host without DNS. There's no option to skip verification.
   - `-L` follows redirects for when the final page is what matters.
   - Several URLs per run; the run is DOWN if any URL is. Every result, up or down, is logged, so the log doubles as an uptime record.
   - Written for bash 3.2 so it also runs on macOS.
4. **CI:** ShellCheck lints both scripts, and the deploy job runs the checker against the freshly deployed `https://wisecow.local/`, verified against the cluster's CA.

Alternatives considered:

- **Python.** Better for parsing and structured output, but these checks are mostly reading `/proc` and calling `curl`, which Bash does with no dependencies.
- **Treat 3xx as up.** A redirect proves something answered, but not that the app works. With `-L` the checker can judge the page the redirect leads to instead.
- **A long-running monitor loop.** Gives continuous output, but no exit code, and it has to be kept alive. cron already handles scheduling.

## Result

- **Monitor**, in a Debian container:
  - Default thresholds: all checks OK, exit 0.
  - Thresholds set to 1: all checks alerted, exit 1, each alert logged with a timestamp, plus memory detail and the top-5 process list.
  - Eight `yes` processes: CPU alert at 98%, exit 1.
  - Bad input or an unwritable log file: exit 2 with a message.
- **Checker**, on macOS with bash 3.2:
  - UP: `https://github.com/` and `https://example.com/` (200).
  - DOWN, each with its reason: a 404, a closed port (connection refused), a server that never answers (timed out at 2 s), an unknown host (DNS), `https://wisecow.local/` without the CA (certificate not trusted), and `http://wisecow.local/` (301).
  - `-L` followed the 301 to the HTTPS endpoint.
  - Usage errors: exit 2.
- Both scripts pass ShellCheck.

## Troubleshooting

- **The disk list showed files as disks.** In a container, `df` lists bind-mounted single files such as `/etc/hosts` as separate filesystems. Fix: skip any mount point that isn't a directory.
- **`ps` reported itself at 150% CPU** in the top-5 list. A process that has only just started gets a meaningless CPU percentage. Fix: drop the pipeline's own `ps` and `head` from the list.
- **The timeout test reported "empty reply" instead of a timeout.** The test server was macOS `nc -l`, which closed the connection because its input was empty. A small Python server that accepts and then sleeps gave the real case: "no response within 2s".
- **The checker found a real outage.** Against the local kind cluster it reported wisecow DOWN: first timeouts, then `HTTP 502` from Traefik after 11 to 15 s. `kubectl` confirmed it: the Docker VM was shared with another kind cluster using over 500% CPU, the wisecow pods had restarted 15 to 18 times on failed liveness probes, and the controller-manager was crash-looping. The script was right; the environment was down.
- **Lesson:** test the failure branches on purpose, with something that actually fails each way. And when a checker says DOWN, believe it until `kubectl` says otherwise.
