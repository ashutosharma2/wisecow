# Wisecow on Kubernetes: the project story (SOART)

Scenario, Obstacle, Action, Result, Troubleshooting. This is how the assessment was planned and built, the decisions behind it, and what went wrong along the way. The detailed reasoning for each decision is in the [ADRs](adr/).

**Status:** both problem statements are done. The image, manifests and TLS are tested on a local kind cluster; the pipeline builds, pushes, deploys by digest to a kind cluster in the runner, and checks it over HTTPS on every commit. The two Problem Statement 2 scripts are tested on Linux and macOS, and the pipeline runs the app checker against each deployment.

---

## S: Scenario

**Containerise and deploy a tiny bash web server on Kubernetes, with CI/CD and TLS.**

This is my Accuknox DevOps Trainee practical assessment. [Wisecow](https://github.com/nyrahul/wisecow) is a bash script that answers every HTTP request with a random `fortune` said by `cowsay`, using netcat on port 4499. The task:

- **Problem Statement 1:** a Dockerfile; Kubernetes manifests that expose the app as a Service; a GitHub Actions workflow that builds and pushes the image on every commit; and two challenge goals, continuous deployment to Kubernetes and TLS.
- **Problem Statement 2:** two of four operational scripts, in Bash or Python.

The deliverable is a public GitHub repository.

## O: Obstacles

1. **The app wasn't written for containers.** It needs OpenBSD netcat for `nc -lN`, finds `fortune` and `cowsay` only if `/usr/games` is on the `PATH`, writes a named pipe into its working directory, and as PID 1 ignores SIGTERM.
2. **It serves one connection at a time.** Netcat restarts between requests, so a single replica can refuse connections during that window, health probes included.
3. **The app can't speak TLS**, and a local cluster has no public domain for a trusted certificate.
4. **The most common ingress controller is retired.** `ingress-nginx` stopped receiving fixes in March 2026 ([ADR-002](adr/002-tls-at-the-ingress.md)).
5. **CI can't reach a laptop.** GitHub's hosted runners have no route to a kind cluster on my machine, so "deploy after every build" needs a cluster the pipeline can reach.
6. **Health checks need exact rules.** CPU usage can't be read in one go, `MemFree` makes a healthy machine look full, and "up" has to cover redirects, hangs and bad certificates, including wisecow's own `http://` redirect ([ADR-004](adr/004-health-scripts.md)).

## A: Actions

### 1. Packaged the script without changing it ([ADR-001](adr/001-container-image.md))

- `debian:trixie-slim` pinned by digest, with exactly `fortune-mod fortunes-min cowsay netcat-openbsd tini`.
- `/usr/games` added to `PATH`, so the script's own prerequisite check passes.
- Runs as UID 10001. The script is read-only; the only writable directory is `/app/run`, where it creates its pipe.
- `tini -g` as PID 1, so stopping the container takes 0.3 s instead of waiting for the 10 s kill.

### 2. Locked down the deployment (`k8s/`)

- Namespace enforces the **restricted** Pod Security Standard, so a pod that runs as root or keeps capabilities is rejected.
- **Two replicas** with `maxUnavailable: 0`, so one pod is always serving while the other restarts netcat, and rollouts never drop to zero. A PodDisruptionBudget keeps at least one up during node maintenance.
- HTTP readiness and liveness probes on `/`, so a pod only gets traffic once it actually returns a cow.
- Read-only root filesystem with `emptyDir` volumes for `/app/run` and `/tmp`; no service-account token; all capabilities dropped; seccomp `RuntimeDefault`.
- Exposed through a `ClusterIP` Service, reached from outside only through the Ingress.

### 3. Added TLS at the ingress ([ADR-002](adr/002-tls-at-the-ingress.md))

- Traefik as the Ingress controller, serving the route on HTTPS only and redirecting HTTP to HTTPS.
- cert-manager issues the `wisecow.local` certificate from a private CA it also manages, and renews it automatically. Clients verify against the CA instead of using `curl -k`.
- A Let's Encrypt ClusterIssuer is ready in `k8s/extras/` for a cluster with a real domain.
- NetworkPolicy: only the Traefik namespace can reach the pods, so TLS can't be bypassed from inside the cluster.

### 4. Made local and CI runs use the same scripts (`hack/`)

- `setup-cluster.sh` creates a kind cluster with ports 80/443 mapped to the host and installs Traefik and cert-manager with pinned versions.
- `deploy.sh <image>` deploys any image by tag or digest through a temporary kustomize overlay, so the manifests in Git never need editing to deploy a new build.
- `smoke-test.sh` checks HTTPS with certificate verification and the HTTP→HTTPS redirect.

### 5. Automated build and deployment ([ADR-003](adr/003-ci-cd-pipeline.md))

- **Registry:** GHCR with the workflow's own `GITHUB_TOKEN`, so no credentials are stored anywhere. Only the build job may push.
- **Continuous deployment without a public cluster:** every push to `main` creates a kind cluster inside the runner, installs Traefik and cert-manager with the same `hack/` scripts, deploys, and runs the TLS smoke test.
- **The cluster pulls from GHCR** through a pull secret made from `GITHUB_TOKEN`, so the pipeline tests the image that was actually published.
- **Pinned by digest:** the deploy uses the exact `sha256` digest the build pushed, and the job fails unless every pod reports that digest.
- `lint → build → deploy`, with ShellCheck, Hadolint and kubeconform first. Pull requests build but don't push or deploy. Actions are pinned to commit SHAs, and the lint tools by image digest or download checksum.

### 6. Wrote two run-once health scripts ([ADR-004](adr/004-health-scripts.md))

- Both are Bash, run once per call, and report three ways: a console line per check, a timestamped log entry, and an exit code (0 healthy, 1 alert or down, 2 bad usage). cron or CI decides when to run them.
- **System health monitor:** CPU from two reads of `/proc/stat` a second apart, memory as `MemTotal − MemAvailable`, disk per real filesystem, and the process count, against thresholds of 80/80/90%/500 that flags can change.
- **App health checker:** 2xx is UP; any other status, a timeout, a refused connection, a DNS failure or a TLS error is DOWN, with the reason. Certificates are always verified (`--cacert` for wisecow's private CA), and `-L` follows redirects when the final page is what matters.
- The pipeline lints both and runs the checker against every deployment.

## R: Results

- `https://wisecow.local` returns 200 with a cow and a certificate that verifies against the cluster CA; `http://` returns 301 to HTTPS.
- Both pods run as non-root under the restricted policy with a read-only filesystem.
- A pod in another namespace can't reach the app directly; Traefik can.
- Manifests and scripts are in Git, and the image builds from a pinned base image. Builds aren't byte-for-byte reproducible: the apt packages aren't version-pinned, and each build stamps its commit and time into the image labels, so every run gets a new digest.
- The pipeline's jobs take about 3 min 17 s from push to a verified HTTPS deployment, with no stored secrets: lint 18 s, build and push for amd64 and arm64 77 s, deploy and smoke test 1 min 42 s. Both pods ran exactly the digest the build pushed.
- The monitor caught a 98% CPU load in a test container and exited 1; the checker told apart 200, 301, 404, refused, timed out, DNS and certificate failures, each with its reason, on bash 3.2.
- In CI, right after each deployment, the checker reports the app UP. In [run 43748030440](https://github.com/ashutosharma2/wisecow/actions/runs/43748030440) that was `https://wisecow.local/` with HTTP 200 in 36 ms, verified against the cluster's CA.

### Known limits

- **Nothing stays deployed.** Continuous deployment targets a kind cluster that exists only for the length of the job, so there's no running environment to open ([ADR-003](adr/003-ci-cd-pipeline.md)).
- **One connection at a time.** Two replicas hide the app's single-connection design; they don't remove it.
- **The pull-request path hasn't run.** Building without pushing or deploying is configured but untested.
- **Lint tools are updated by hand.** ShellCheck, Hadolint and kubeconform are pinned; Dependabot only covers the actions and the base image.
- **The health monitor is Linux-only**, because it reads `/proc`.

## T: Troubleshooting

1. **The third request failed.** Two quick requests worked and a third got no response. Sixty more requests at different gaps all worked, so it's the brief netcat restart window, not a bug. Fix: two replicas behind the Service. Lesson: test several requests, not one.
2. **The cluster wouldn't create pods.** After `kubectl apply`, the Deployment sat at 0/2 with no events. `kube-controller-manager` and `kube-scheduler` were in CrashLoopBackOff with `leaderelection lost`: two kind clusters were sharing a 4 GB Docker VM and the API server was too slow to renew their leases. They recovered on their own after a few restarts and both pods came up. Lesson: when a Deployment shows no events at all, check the control plane before the manifest. The real fix is giving the local cluster room: stop the other cluster, or raise Docker's memory limit.
3. **The smoke test stopped silently.** HTTPS passed, then the script exited without a message. `read` returned 1 because curl's `-w` output had no trailing newline, and `set -e` ended the script. Lesson: end parsed `curl -w` formats with `\n`.
4. **The workflow failed lint before it ever ran.** actionlint flagged Markdown backticks inside single quotes in the run-summary step (ShellCheck SC2016). They were intentional, but the line was rewritten so the lint stays clean. Lesson: run `actionlint` on workflow files before pushing; otherwise CI mistakes only show up as failed runs.
5. **The recreated repository couldn't push its image.** I deleted and recreated the repository to clean up its commit history, and its first build failed with `permission_denied: write_package`. The GHCR package from the old repository was still there, because deleting a repository doesn't delete its packages, and only the old repository could write to it. Deleting the package and rerunning the failed jobs fixed it. Lesson: a GHCR package outlives its repository.
6. **The app checker found a real outage.** Run against the local cluster, it reported wisecow DOWN: timeouts, then `HTTP 502` from Traefik. `kubectl` showed why. The Docker VM was shared with another kind cluster using over 500% CPU, wisecow's pods had restarted 15 to 18 times on failed liveness probes, and the controller-manager was crash-looping. This was the same contention as entry 2, back under heavier load, and I hadn't fixed it the first time. Lesson: when a checker says DOWN, believe it until `kubectl` says otherwise, and fix an environment problem the first time it shows up.
7. **Container quirks in the monitor's first run.** `df` listed bind-mounted files like `/etc/hosts` as disks, and `ps` reported itself at 150% CPU in the top-5 list. Both are now filtered out. Lesson: test a system script where it will actually run, not just where it was written.
8. **CI rejected lint that passed locally.** The runner's ShellCheck flagged two `A && B || die` lines (SC2015) that my local v0.11.0 accepted. They became explicit `if` statements and now pass v0.9 to v0.11, and CI now runs the same pinned ShellCheck image as my machine. Lesson: lint locally with the version CI uses, and pin it.
9. **A reviewer's read found my own overstatements.** Reading the README and ADRs as a reviewer turned up a wrong cross-reference, two "nothing else changes" claims that weren't true, an unsourced claim, and a README hint (`kubectl apply -k k8s`) that fails on a cluster without cert-manager. It also showed that the GHCR package is public, although the docs said new packages are private. All are fixed. Lesson: check every claim in the docs against the code or a real request, not against memory.
