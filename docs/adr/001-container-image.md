# ADR-001: A small Debian image that runs the upstream script unchanged, as non-root

- Status: Accepted
- Date: 2026-11-15

## Scenario

Wisecow is a single bash script, `wisecow.sh`. It serves `fortune | cowsay` as an HTTP response on port 4499 using netcat and a named pipe. The assessment asks for a Dockerfile that packages it so it can run on Kubernetes.

## Obstacle

The script looks trivial, but it makes assumptions about its environment that a container doesn't meet by default:

- **It needs OpenBSD netcat.** It runs `nc -lN`. The `-N` flag (close the connection when input ends) only exists in the OpenBSD variant. Other netcats either reject it or never close the connection, so the browser hangs.
- **Debian puts `fortune` and `cowsay` in `/usr/games`**, which isn't on the container's `PATH`. (Debian adds it for normal login users, which is why the script works on a desktop, but not in images or for root.) The script's own prerequisite check fails and it exits with "Install prerequisites."
- **`fortune-mod` alone has no fortunes.** With `--no-install-recommends` the fortune database isn't installed, and `fortune` prints nothing.
- **It writes to its working directory.** It creates a named pipe called `response` in the current directory at startup, so that directory must be writable. That conflicts with a read-only root filesystem.
- **Bash as PID 1 ignores SIGTERM.** Without an init process, `docker stop` and pod termination wait for the full grace period and then kill the container.
- **It serves one connection at a time.** Between requests, netcat restarts, so concurrent requests are refused.

## Action

1. Base image `debian:trixie-slim`, pinned by digest so every build starts from the same bytes. Dependabot proposes digest updates.
2. Install exactly `fortune-mod fortunes-min cowsay netcat-openbsd tini` with `--no-install-recommends`, and clear the apt lists in the same layer.
3. `ENV PATH="/usr/games:${PATH}"` so the script finds `fortune` and `cowsay` without being edited.
4. Run as a fixed non-root user (UID/GID 10001). The script is copied read-only (`0555`) to `/app/wisecow.sh`. The only writable path is the working directory `/app/run`, owned by that user. In Kubernetes, `/app/run` and `/tmp` are `emptyDir` volumes, so the root filesystem can be read-only.
5. `tini -g` as the entrypoint. It forwards SIGTERM to the whole process group and reaps the `nc`/`cat` children the script spawns.
6. Leave `wisecow.sh` unchanged. The single-connection limit is handled at the deployment level, not by rewriting the app: two replicas behind the Service, with `maxUnavailable: 0` so a rollout never drops to zero (`k8s/deployment.yaml`; Action 2 in the [project story](../project-story.md)).
7. `.dockerignore` sends only `wisecow.sh` to the build context.

Alternatives considered:

- **Alpine.** Smaller, but `cowsay` and `fortune` come from community packages with different paths and fortune sets, and BusyBox `nc` has no `-N`. Saving about 100 MB wasn't worth replacing the tools the script was written for.
- **Fixing the app (e.g. `socat` or a real web server).** Would remove the one-connection limit, but the task is to containerise and deploy this app, not to rewrite it.
- **`docker run --init` instead of tini.** Works for Docker but not for Kubernetes, which has no equivalent flag.

## Result

- Image size 214 MB (mostly perl, which `cowsay` needs).
- `docker run -p 4499:4499 wisecow` returns HTTP 200 with a cow; `id` inside the container shows `uid=10001(wisecow)`.
- `docker stop` takes about 0.3 s instead of the 10 s timeout, because tini forwards the signal.
- The same image runs unchanged under the Kubernetes "restricted" Pod Security Standard with a read-only root filesystem.

## Troubleshooting

- **How it was found.** In the first local test, two quick requests returned 200 and a third returned no response (`HTTP 000`). A later run of 60 sequential requests at different gaps all succeeded, so the failure is a narrow window while netcat restarts, not a broken image. That's the single-connection design of the script.
- **Lesson:** run several requests in a row, not just one, before calling a server "working". A single success hides concurrency limits.
