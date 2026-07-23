# Deploy: force llamacpp + chatbot to repull on every deploy

**Date:** 2026-07-23
**Scope:** `scripts/faig/deploy.sh`, `scripts/faig/values.yaml`

## Problem

`deploy.sh` runs `helm upgrade --install` against prebuilt images pulled from
the registry (`fortiaigate.azurecr.io/llamacpp:v1`,
`fortiaigate.azurecr.io/chatbot:v1`). Because the images use a **mutable tag**
(`v1`) and `imagePullPolicy: IfNotPresent`, pushing a new image to the same tag
does **not** get picked up on redeploy: `helm upgrade` sees an unchanged pod
template (same tag) so it recreates nothing, and even a manual pod restart
reuses the node-cached layer. The running pods silently keep the old image.

The goal is for each deploy to re-pull and restart the two app containers
(`llamacpp`, `chatbot`) so a freshly-pushed `v1` is always the one running.
`landing` (stock nginx, not built from this workshop) is out of scope.

## Chosen approach — Mechanism A: always restart

Decided against digest-diffing. On every run, unconditionally force the two app
deployments to re-pull and roll. No registry queries, no new tooling — just
`kubectl`. Registry-agnostic (works for ACR or any other registry).

Accepted cost: `llamacpp` reloads its GGUF model and re-`mlock`s it into RAM on
every deploy, so each run incurs tens of seconds to a couple minutes of
`llamacpp` downtime even when the image did not change. The `REPULL=0` opt-out
(below) exists precisely to avoid paying this when redeploying for unrelated
reasons (e.g. landing/config tweaks).

## Changes

### 1. `values.yaml` — pull policy `Always` for the two app images

- `llamacpp.image.pullPolicy`: `IfNotPresent` → `Always`
- `chatbot.image.pullPolicy`: `IfNotPresent` → `Always`
- `landing.image.pullPolicy`: unchanged (`IfNotPresent`).

Required because a `rollout restart` recreates pods, but under `IfNotPresent` a
node that already cached `v1` reuses the stale layer. `Always` guarantees the
recreated pod pulls the current `v1` from the registry.

### 2. `deploy.sh` — new "repull" step

Added after the `helm upgrade --install` block and before the URL print
(current step 5). Behavior:

- Gated by an env knob: `REPULL="${REPULL:-1}"`. When `REPULL=0`, the whole step
  is skipped with a notice and the deploy proceeds without rolling the pods.
- When enabled, for each app component in order — `llamacpp` (namespace
  `llamacpp`, deployment `llamacpp`), then `chatbot` (namespace `chatbot`,
  deployment `chatbot`):
  - If the deployment does not exist (component disabled or first-run race),
    print a skip notice and continue — not a hard error.
  - Otherwise: `kubectl -n <ns> rollout restart deploy/<name>` followed by
    `kubectl -n <ns> rollout status deploy/<name> --timeout=10m`.

`landing` is never touched by this step.

## Data / control flow

```
helm upgrade --install (existing, --wait)
        │
        ▼
REPULL == 1 ?  ──no──►  skip, print notice
        │yes
        ▼
for (ns=llamacpp, deploy=llamacpp), then (ns=chatbot, deploy=chatbot):
    deploy exists?  ──no──►  print skip notice, continue
        │yes
        ▼
    kubectl rollout restart  →  kubectl rollout status --timeout=10m
        │
        ▼
print access URLs (existing)
```

## Error handling

- `set -euo pipefail` is already in effect; the repull step must not abort the
  run merely because a component is disabled — hence the explicit
  "deployment exists?" guard before restart.
- `rollout status --timeout=10m` matches the existing `helm ... --timeout 10m`;
  a genuinely stuck rollout surfaces as a non-zero exit, which is the correct
  failure signal.

## Testing / verification

- `REPULL=0 ./deploy.sh` skips the restart step (verify via the skip notice and
  that pod `AGE` is unchanged after the run).
- Default run: after deploy, `kubectl -n llamacpp get pods` and
  `kubectl -n chatbot get pods` show freshly-restarted pods (recent `AGE`), and
  their `imageID` reflects the current registry digest.
- Push a new image to `v1`, redeploy, confirm the new digest is running.
- Component disabled (`chatbot.enabled: false`): deploy prints the skip notice
  for chatbot and completes without error.

## Out of scope

- Building or pushing the images (done out-of-band; no Dockerfile for the
  llamacpp image lives in this repo).
- Digest comparison / change detection.
- The `landing` container.
- The separate `ansible-chatbot` VM/docker-compose deployment path.
