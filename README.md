# Wisecow on Kubernetes

[![CI/CD](https://github.com/ashutosharma2/wisecow/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/ashutosharma2/wisecow/actions/workflows/ci-cd.yml)

My submission for the Accuknox DevOps Trainee practical assessment: containerise the [Wisecow](https://github.com/nyrahul/wisecow) app, deploy it on Kubernetes behind TLS, and automate the build and deployment with GitHub Actions.

Wisecow is a bash script that answers every HTTP request with a random `fortune` said by `cowsay`. I haven't changed the script itself (`wisecow.sh`); everything else in this repo is built around it.

**[Read the project story](docs/project-story.md)**: the problems, decisions and fixes behind this repo, in SOART format. The reasoning for each decision is in the [ADRs](docs/adr/).

## Status

| Requirement | State |
|---|---|
| Dockerfile | Done ([ADR-001](docs/adr/001-container-image.md)) |
| Kubernetes manifests, exposed as a Service | Done: ClusterIP Service `wisecow:80`, reached through the Ingress or `kubectl port-forward` |
| TLS (challenge goal) | Done ([ADR-002](docs/adr/002-tls-at-the-ingress.md)) |
| GitHub Actions: build and push on every commit | Done ([ADR-003](docs/adr/003-ci-cd-pipeline.md)) |
| Continuous deployment (challenge goal) | Done: deploys each build by digest to kind in the runner and smoke-tests it |
| Problem Statement 2: two scripts | Done: [system health monitor and app health checker](problem-statement-2/) ([ADR-004](docs/adr/004-health-scripts.md)) |

## How it works

```
browser ──HTTPS──▶ Traefik Ingress ──HTTP──▶ Service wisecow:80 ──▶ pod :4499 (x2)
          wisecow.local     │ TLS cert from cert-manager        │
          (http → 301 https)│ (private CA, auto-renewed)        │ NetworkPolicy: only
                                                                │ Traefik may connect
```

- **Image:** Debian slim with fortune, cowsay, OpenBSD netcat and tini; runs as non-root UID 10001 ([ADR-001](docs/adr/001-container-image.md)).
- **Workload:** two replicas, because the script serves one connection at a time. HTTP probes, read-only root filesystem, no capabilities, restricted Pod Security Standard.
- **TLS:** terminated at the Traefik Ingress; cert-manager issues and renews the certificate ([ADR-002](docs/adr/002-tls-at-the-ingress.md)).

## CI/CD pipeline

[`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml) runs on every push to `main` ([ADR-003](docs/adr/003-ci-cd-pipeline.md)):

```
lint ──▶ build ─────────────────────▶ deploy ─────────────────────────▶ verify
         amd64 + arm64, pushed to      kind cluster inside the runner,    smoke test: HTTPS 200 with a verified
         GHCR with GITHUB_TOKEN        pulls from GHCR, pinned to the     certificate, HTTP → HTTPS
         (tags sha-<short>, latest)    pushed digest                      app_health_checker.sh: UP
                                                                          every pod runs that exact digest
```

- The pipeline stores no credentials. The GHCR login and the cluster's pull secret both use the job's own `GITHUB_TOKEN`.
- Pull requests run lint and build only.
- Images: `ghcr.io/ashutosharma2/wisecow`.

## Problem Statement 2

Two Bash scripts in [`problem-statement-2/`](problem-statement-2/), both run once and report through a log file and their exit code ([ADR-004](docs/adr/004-health-scripts.md)):

- **`system_health_monitor.sh`** checks CPU (from `/proc/stat`), memory, disk and process count against thresholds and logs every alert.
- **`app_health_checker.sh`** reports a URL as UP only on a 2xx response; any other status, a timeout or a TLS error is DOWN. The pipeline runs it against every deployment.

## Run it locally

Needs Docker, [kind](https://kind.sigs.k8s.io/), kubectl and Helm.

```bash
hack/setup-cluster.sh
```

```bash
docker build -t wisecow:local .
```

```bash
kind load docker-image wisecow:local --name wisecow
```

```bash
hack/deploy.sh wisecow:local
```

```bash
hack/smoke-test.sh
```

`setup-cluster.sh` creates a kind cluster with host ports 80 and 443 mapped in and installs Traefik and cert-manager. `deploy.sh` deploys any image by tag or digest. `smoke-test.sh` checks HTTPS with certificate verification and the HTTP→HTTPS redirect.

To open it in a browser, add `127.0.0.1 wisecow.local` to `/etc/hosts` and trust the CA:

```bash
kubectl -n wisecow get secret wisecow-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > wisecow-ca.crt
```

To reach the Service directly, without the Ingress, then open http://localhost:8080:

```bash
kubectl -n wisecow port-forward svc/wisecow 8080:80
```

### On another cluster

`k8s/` needs two add-ons first: cert-manager (4 of its resources are cert-manager kinds) and the Traefik ingress controller (the Ingress uses class `traefik`, and the NetworkPolicy admits only the `traefik` namespace). With both installed, `kubectl apply -k k8s` deploys the public image `ghcr.io/ashutosharma2/wisecow:latest`. To pin a specific build, run `hack/deploy.sh ghcr.io/ashutosharma2/wisecow@sha256:<digest>` instead.

## Repository layout

```
wisecow.sh              the app (upstream, unchanged)
Dockerfile              container image
k8s/                    Kubernetes manifests (kustomize; needs cert-manager and Traefik)
  extras/               Let's Encrypt issuer for clusters with a real domain
hack/                   kind cluster setup, deploy and smoke-test scripts
.github/workflows/      CI/CD pipeline
problem-statement-2/    health monitor and app health checker scripts
docs/project-story.md   SOART write-up
docs/adr/               architecture decision records
LOG.md, NEXT.md         build log and the next task
```

## Running the original script

```bash
sudo apt install fortune-mod cowsay netcat-openbsd -y
```

```bash
./wisecow.sh
```

Then open http://localhost:4499.
