# Wisecow on Kubernetes: the project story (SOART)

Scenario, Obstacle, Action, Result, Troubleshooting. This is how the assessment was planned and built, the decisions behind it, and what went wrong along the way. The detailed reasoning for each decision is in the [ADRs](adr/).

**Status:** in progress. The container image, the Kubernetes manifests and TLS are built and tested on a local kind cluster. The GitHub Actions pipeline builds and pushes the image on every commit, then deploys it by digest to a kind cluster in the runner and runs the TLS smoke test; the first run passed end to end. Next are the two Problem Statement 2 scripts.

---

## S: Scenario

**Containerise and deploy a tiny bash web server on Kubernetes, with CI/CD and TLS.**

This is my Accuknox DevOps Trainee practical assessment. [Wisecow](https://github.com/nyrahul/wisecow) is a bash script that answers every HTTP request with a random `fortune` said by `cowsay`, using netcat on port 4499. The task:

- **Problem Statement 1:** a Dockerfile; Kubernetes manifests that expose the app as a Service; a GitHub Actions workflow that builds and pushes the image on every commit; and two challenge goals, continuous deployment to Kubernetes and TLS.
- **Problem Statement 2:** two of four operational scripts, in Bash or Python.

The deliverable is a public GitHub repository.

## O: Obstacles

1. **The app wasn't written for containers.** It needs OpenBSD netcat for `nc -lN`, finds `fortune` and `cowsay` only if `/usr/games` is on the `PATH`, writes a named pipe into its working directory, and as PID 1 ignores SIGTERM.
2. **It serves one connection at a time.** Netcat restarts between requests, so a single replica refuses connections during that window, including the kubelet's health probes.
3. **The app can't speak TLS**, and a local cluster has no public domain for a trusted certificate.
4. **The most common ingress controller is retired.** `ingress-nginx` stopped receiving fixes in March 2026.
5. **CI can't reach a laptop.** GitHub's hosted runners have no route to a kind cluster on my machine, so "deploy after every build" needs a cluster the pipeline can reach.

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
- `lint → build → deploy`, with ShellCheck, Hadolint and kubeconform first. Pull requests build but don't push or deploy. Actions are pinned to commit SHAs.

## R: Results

- `https://wisecow.local` returns 200 with a cow and a certificate that verifies against the cluster CA; `http://` returns 301 to HTTPS.
- Both pods run as non-root under the restricted policy with a read-only filesystem.
- A pod in another namespace can't reach the app directly; Traefik can.
- Manifests and scripts are in Git; the image builds reproducibly from a pinned base.
- The first pipeline run went from push to a verified HTTPS deployment in 3 min 12 s, with no stored secrets: lint 11 s, build and push for amd64 and arm64 75 s, deploy and smoke test 1 min 42 s. Both pods ran exactly the digest the build pushed.

## T: Troubleshooting

1. **The third request failed.** Two quick requests worked and a third got no response. Sixty more requests at different gaps all worked, so it's the brief netcat restart window, not a bug. Fix: two replicas behind the Service. Lesson: test several requests, not one.
2. **The cluster wouldn't create pods.** After `kubectl apply`, the Deployment sat at 0/2 with no events. `kube-controller-manager` and `kube-scheduler` were in CrashLoopBackOff with `leaderelection lost`: two kind clusters were sharing a 4 GB Docker VM and the API server was too slow to renew their leases. They recovered on their own after a few restarts and both pods came up. Lesson: when a Deployment shows no events at all, check the control plane before the manifest.
3. **The smoke test stopped silently.** HTTPS passed, then the script exited without a message. `read` returned 1 because curl's `-w` output had no trailing newline, and `set -e` ended the script. Lesson: end parsed `curl -w` formats with `\n`.
4. **The workflow failed lint before it ever ran.** actionlint flagged Markdown backticks inside single quotes in the run-summary step (ShellCheck SC2016). They were intentional, but the line was rewritten so the lint stays clean. Lesson: run `actionlint` on workflow files before pushing; otherwise CI mistakes only show up as failed runs.
