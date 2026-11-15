# Next session: one task

**Design and build the GitHub Actions pipeline: build and push on every commit, then deploy**

The image builds and the manifests deploy and pass the TLS smoke test locally. The pipeline has to:

1. Build the image and push it to a container registry on every push to `main`.
2. Challenge goal: deploy the new image to Kubernetes automatically after a successful build.

Open questions to decide first:

- Which registry, and how the workflow authenticates to it.
- Which cluster the deploy step targets, given GitHub's hosted runners can't reach a kind cluster on a laptop.
- How the deploy pins the exact image that was just built (tag vs digest).

Done when: a push to `main` builds and pushes an image, the deploy job rolls it out, and the run passes the smoke test.
