# Wisecow on Kubernetes

Accuknox DevOps Trainee practical assessment: containerise the [Wisecow](https://github.com/nyrahul/wisecow) app, deploy it on Kubernetes behind TLS, and automate build and deployment with GitHub Actions.

Wisecow is a bash script that answers every HTTP request with a random `fortune` said by `cowsay`. The app script, `wisecow.sh`, is unchanged from upstream.

**[Read the project story](docs/project-story.md)**: the problems, decisions and fixes behind this repo, in SOART format. The reasoning for each decision is in the [ADRs](docs/adr/).

## Status

| Requirement | State |
|---|---|
| Dockerfile | Done ([ADR-001](docs/adr/001-container-image.md)) |
| Kubernetes manifests, exposed as a Service | Done |
| TLS (challenge goal) | Done ([ADR-002](docs/adr/002-tls-at-the-ingress.md)) |
| GitHub Actions: build and push on every commit | In progress |
| Continuous deployment (challenge goal) | In progress |
| Problem Statement 2: two scripts | Not started |

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

## Repository layout

```
wisecow.sh              the app (upstream, unchanged)
Dockerfile              container image
k8s/                    Kubernetes manifests (kustomize): kubectl apply -k k8s
  extras/               Let's Encrypt issuer for clusters with a real domain
hack/                   kind cluster setup, deploy and smoke-test scripts
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
