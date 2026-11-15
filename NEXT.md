# Next session: one task

**Problem Statement 2: build two of the four operational scripts**

Problem Statement 1 is complete: the image, manifests, TLS and the CI/CD pipeline are in place, and the first pipeline run deployed and smoke-tested the image by digest.

Choose two of:

1. System health monitor (CPU, memory, disk, processes; alert over a threshold)
2. Automated backup (directory to a remote server or cloud storage; success/failure report)
3. Log file analyzer (404s, top pages, top IPs from web server logs)
4. Application health checker (up/down from HTTP status codes)

Decide the language (Bash or Python), what each script measures, what counts as an alert or "down", and what it reports (output, log file, exit code).

Done when: both scripts are in the repo with usage instructions and tested against real input.
