# ADR-002: Terminate TLS at a Traefik Ingress with cert-manager certificates

- Status: Accepted
- Date: 2026-11-15

## Scenario

The app must be reachable through a Kubernetes Service, and the challenge goal is secure TLS communication. Wisecow itself only speaks plain HTTP over netcat; it has no TLS support.

## Obstacle

- **The app can't do TLS.** Adding TLS inside `wisecow.sh` would mean wrapping netcat in something like `openssl s_server` or `socat`, changing the app.
- **Certificates expire and must be rotated.** A certificate created by hand with `openssl` and stored in a Secret works once, then silently expires.
- **A local cluster has no public domain**, so Let's Encrypt can't issue a certificate for it. A plain self-signed certificate forces every client to skip verification (`curl -k`), which proves nothing about TLS.
- **The usual default controller is gone.** The community `ingress-nginx` controller was retired in March 2026 and no longer gets fixes, so it's a poor choice for a new deployment.
- **Only the ingress should reach the pods.** If any pod in the cluster can talk to wisecow on plain HTTP, TLS at the edge can be bypassed from inside.

## Action

1. **Service:** `ClusterIP` on port 80, targeting the container's named port `http` (4499). It isn't exposed outside the cluster by itself.
2. **Ingress controller: Traefik**, installed with Helm. It is actively maintained and supports the standard `networking.k8s.io/v1` Ingress API, so the manifest isn't tied to Traefik apart from two annotations.
3. **Ingress:** host `wisecow.local`, `tls` section using Secret `wisecow-tls`. The router listens only on the HTTPS entrypoint, and Traefik redirects all plain HTTP to HTTPS (301).
4. **Certificates from cert-manager**, from a small private CA:
   `selfsigned` Issuer → `wisecow-ca` (CA certificate) → `wisecow-ca-issuer` → `wisecow-tls` (90 days, renewed 15 days before expiry, ECDSA P-256, new key on every renewal).
   Clients verify the server against `ca.crt` from Secret `wisecow-ca` instead of turning verification off.
5. **Production path:** `k8s/extras/letsencrypt-clusterissuer.yaml` is a Let's Encrypt ClusterIssuer (HTTP-01 through Traefik). On a cluster with a real domain, the Certificate's `issuerRef` points at it instead. Nothing else changes.
6. **NetworkPolicy:** default-deny ingress in the `wisecow` namespace, then allow TCP 4499 only from the `traefik` namespace.

Alternatives considered:

- **TLS in the pod (sidecar or `socat` wrapper).** End-to-end encryption to the pod, but more moving parts per pod and certificate mounting in every replica. Not needed when the hop from ingress to pod is inside the cluster and locked down by NetworkPolicy.
- **Hand-made certificate in a Secret.** Simplest, but no renewal, and the private key ends up on a laptop.
- **Gateway API instead of Ingress.** The newer API, but it needs extra CRDs and cert-manager's Gateway support switched on. Ingress is enough for one host and one route.

## Result

- `https://wisecow.local` returns 200 with a cow, and `curl --cacert ca.crt` verifies the chain (`ssl_verify_result 0`). Subject `CN=wisecow.local`, issuer `CN=wisecow-ca`.
- `http://wisecow.local` returns `301` to `https://wisecow.local/`.
- A pod in the `default` namespace can't connect to the wisecow Service directly; Traefik can.
- cert-manager renews the certificate before it expires, so I never rotate it by hand.

## Troubleshooting

- **The smoke test passed HTTPS, then exited silently on the redirect check.** The check reads curl's output with `read -r code location`. curl's `-w` format had no trailing newline, so `read` hit end-of-file and returned 1, and `set -e` stopped the script without an error message. Adding `\n` to the format fixed it.
- **Lesson:** under `set -e`, `read` fails on input without a final newline. Always end `curl -w` formats with `\n` when the output is parsed.
