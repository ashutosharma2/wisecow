# ADR-003: Push to GHCR with GITHUB_TOKEN, then deploy by digest to a kind cluster inside the runner

- Status: Accepted
- Date: 2026-11-15

## Scenario

Every commit must build the image and push it to a container registry. The challenge goal is to deploy the new image to Kubernetes automatically after a successful build.

## Obstacle

- **GitHub's hosted runners can't reach my cluster.** The kind cluster runs on my laptop, behind my home network, with no public address. A managed cloud cluster would be reachable, but it costs money every hour and needs a long-lived kubeconfig stored as a secret.
- **Registry credentials are another secret to manage.** Docker Hub needs a stored access token that can leak and has to be rotated.
- **Tags move.** `latest`, or even `sha-<commit>`, can be pushed over. A deploy that names a tag can end up running something other than what was just built and tested.
- **A GHCR package may be private.** GitHub's documented default for a new package is private, and a cluster can't pull a private image anonymously.
- **Pull requests from forks get a read-only token**, so they can't push images.

## Action

1. **Registry: GitHub Container Registry**, authenticated with the workflow's built-in `GITHUB_TOKEN`. The repository stores no credentials. Only the build job gets `packages: write`; the deploy job gets `packages: read`; everything else is `contents: read`.
2. **Deploy target: a kind cluster created inside the runner** for every push to `main`. It runs the same `hack/` scripts used locally: cluster config, Traefik and cert-manager, deploy, smoke test.
3. **The cluster pulls the image from GHCR**, through a `docker-registry` pull secret made from `GITHUB_TOKEN` and attached to the namespace's default ServiceAccount. That tests the artifact that was actually published, not a copy loaded from the runner's local Docker. The token expires when the job ends, and so does the cluster.
4. **Deploy by digest.** The build job outputs the digest of the image it pushed, and the deploy job runs `hack/deploy.sh ghcr.io/ashutosharma2/wisecow@sha256:…`. After the smoke test, the job checks that every running pod reports that same digest.
5. **Pipeline shape:** `lint → build → deploy`. Lint runs ShellCheck, Hadolint and kubeconform (cert-manager schemas from the CRDs catalog) so mistakes fail in seconds. Pull requests are configured to run lint and build only, and never push or deploy (not yet exercised by a real pull request).
6. **Images for both architectures** (`linux/amd64`, `linux/arm64`), tagged `sha-<short commit>` and, on `main`, `latest`. Tags are for people; deploys use the digest.
7. **Supply chain:** every third-party action is pinned to a commit SHA, the ShellCheck and Hadolint images are pinned by digest, and the kubeconform download is checked against its published SHA-256. Dependabot proposes updates for the actions and the base image; the lint tool versions are bumped by hand.
8. **Evidence:** the run summary lists the pushed digest and tags and the deployed image. If deploy or the smoke test fails, the job prints pods, events and controller logs before the cluster disappears.

Alternatives considered:

- **A managed cloud cluster with a stored kubeconfig.** A persistent environment people could open, but it costs money continuously and puts a long-lived cluster credential in GitHub secrets.
- **A self-hosted runner on my laptop.** Could deploy to the local cluster, but only while the laptop is on, and it runs repository code on my machine.
- **Load the image into kind with `kind load`.** Faster, but skips the registry, so a broken push or a permission problem wouldn't fail the pipeline.
- **Deploy by tag.** Readable, but the tag can be moved between the build and the deploy.

## Result

First run on 2026-11-15 ([run 43740820098](https://github.com/ashutosharma2/wisecow/actions/runs/43740820098)). The first attempt was refused at the push (see Troubleshooting); the second attempt passed:

- **Lint** passed in 18 s.
- **Build and push** passed in 77 s for both architectures, with no stored credentials. GHCR received `ghcr.io/ashutosharma2/wisecow@sha256:9de0f5f314e48f0e450c9c68d1ea05ca8b98a31fbfa4d07f7bd39117412a7095`, tagged `sha-<short commit>` and `latest`.
- **Deploy to kind and smoke test** passed in 1 min 42 s: cluster created, Traefik and cert-manager installed, the image pulled from GHCR through the pull secret, `https://wisecow.local` returned 200 with a certificate that verified against the cluster CA (subject `CN = wisecow.local`, issuer `CN = wisecow-ca`), and `http://` returned 301 to HTTPS.
- **Both pods ran exactly the pushed digest** (`imageID` `…@sha256:9de0f5f3…`), so the image built in this run is the one that was tested.
- The three jobs take about 3 min 17 s from push to a verified HTTPS deployment.
- **Limit:** the cluster is deleted when the job ends, so there is no environment left running to open. A persistent cluster would need a stored credential (see Alternatives).
- **The package came out public.** An anonymous pull of `ghcr.io/ashutosharma2/wisecow` works (HTTP 200 without credentials), so for this public repository the pull secret is a safeguard rather than a requirement. It keeps the pipeline working if the package is ever made private.

## Troubleshooting

- **actionlint caught a false alarm before the first push.** The run-summary step used `sed 's/^/- `/'` to wrap tags in Markdown backticks. ShellCheck (inside actionlint) reported SC2016, "expressions don't expand in single quotes", because it reads backticks as command substitution. The backticks were meant literally, but the line was rewritten as a `while read` loop so the lint stays clean and a real warning can't hide among accepted ones.
- **Lesson:** lint the workflow file itself before pushing (`actionlint`). A mistake in CI configuration otherwise only shows up after a push, as a failed run.
- **The new repository couldn't push its image.** I deleted and recreated the repository to clean up its commit history. The first build in the new repository failed with `denied: permission_denied: write_package`. Deleting a repository doesn't delete its GHCR packages: the old `wisecow` package still existed, and only the deleted repository was allowed to write to it. Deleting the package and rerunning the failed jobs fixed it; the rerun created a fresh package owned by the new repository.
- **Lesson:** a GHCR package outlives its repository. Before reusing a repository name, delete the old package or give the new repository write access to it (Package settings → Manage Actions access).
