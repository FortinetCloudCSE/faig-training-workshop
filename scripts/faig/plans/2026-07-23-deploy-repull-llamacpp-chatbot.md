# Deploy Repull (llamacpp + chatbot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `./deploy.sh` run force the `llamacpp` and `chatbot` pods to re-pull their registry image and restart, so a newly-pushed `v1` is always what runs.

**Architecture:** Mechanism A ("always restart"). Set `imagePullPolicy: Always` on the two app images so recreated pods pull the tag fresh, and add a `kubectl rollout restart` + `rollout status` step to `deploy.sh` after the existing `helm upgrade`. Gated by a `REPULL` env knob (default on). `landing` is untouched.

**Tech Stack:** Bash, kubectl, Helm, a Helm chart (`llm-stack`).

## Global Constraints

- Spec: `scripts/faig/specs/2026-07-23-deploy-repull-llamacpp-chatbot-design.md`.
- `deploy.sh` runs under `set -euo pipefail` — the repull step must not abort the run when a component is disabled/absent (guard with an existence check).
- Only `llamacpp` (ns `llamacpp`, deploy `llamacpp`) and `chatbot` (ns `chatbot`, deploy `chatbot`) are affected. `landing` stays `IfNotPresent` and is never restarted.
- No shellcheck available in this environment; verify Bash with `bash -n`. `helm` is available for template-render checks.
- `rollout status` timeout is `10m`, matching the existing `helm ... --timeout 10m`.

---

### Task 1: Set `imagePullPolicy: Always` for llamacpp and chatbot

**Files:**
- Modify: `scripts/faig/values.yaml:27` (llamacpp `pullPolicy`)
- Modify: `scripts/faig/values.yaml:93` (chatbot `pullPolicy`)

**Interfaces:**
- Consumes: nothing.
- Produces: rendered Deployment manifests for `llamacpp` and `chatbot` carry `imagePullPolicy: Always`; `landing` still renders `IfNotPresent`. Task 2's `rollout restart` relies on this to guarantee a fresh pull.

- [ ] **Step 1: Change llamacpp pull policy**

In `scripts/faig/values.yaml`, under `llamacpp.image` (line 27), change:

```yaml
    pullPolicy: IfNotPresent
```

to:

```yaml
    pullPolicy: Always
```

- [ ] **Step 2: Change chatbot pull policy**

In `scripts/faig/values.yaml`, under `chatbot.image` (line 93), change:

```yaml
    pullPolicy: IfNotPresent
```

to:

```yaml
    pullPolicy: Always
```

Leave `landing.image.pullPolicy` (~line 130) as `IfNotPresent`.

- [ ] **Step 3: Verify the render**

Run:

```bash
cd scripts/faig
helm template llm-stack ./llm-stack -f values.yaml \
  | grep -E 'image:|imagePullPolicy:'
```

Expected: the `llamacpp` and `chatbot` containers show `imagePullPolicy: Always`; the `landing`/nginx container shows `imagePullPolicy: IfNotPresent`.

- [ ] **Step 4: Commit**

```bash
git add scripts/faig/values.yaml
git commit -m "Set imagePullPolicy Always for llamacpp and chatbot"
```

---

### Task 2: Add the gated repull step to deploy.sh

**Files:**
- Modify: `scripts/faig/deploy.sh` — add config knob near the other env overrides (after line 23, `ACR_NAME=...`); add the repull block after the `helm upgrade --install` block (after line 138) and before the "5. Print URLs" comment (line 140).

**Interfaces:**
- Consumes: `Always` pull policy from Task 1; the existing `helm upgrade --install ... --wait` having already created/updated the deployments.
- Produces: after a default run, `llamacpp` and `chatbot` pods are freshly restarted and running the current registry image. `REPULL=0` skips the step.

- [ ] **Step 1: Add the REPULL knob**

In `scripts/faig/deploy.sh`, immediately after the `ACR_NAME` line (line 23), add:

```bash
# Force a re-pull + restart of the app containers (llamacpp, chatbot) after the
# helm upgrade so a newly-pushed image on the same tag is picked up. These images
# use imagePullPolicy: Always (values.yaml), so recreating the pod pulls the tag
# fresh. Set REPULL=0 to skip (e.g. when only tweaking landing/config and you
# don't want to pay the llamacpp model reload).
REPULL="${REPULL:-1}"
```

- [ ] **Step 2: Add the repull block**

In `scripts/faig/deploy.sh`, after the `helm upgrade --install` block ends (the line `  --wait --timeout 10m`, line 138) and before the `# 5. Print URLs...` comment (line 140), insert:

```bash

# 4b. Force llamacpp + chatbot to re-pull and restart so a newly-pushed image on
#     the same tag is picked up. helm upgrade alone won't notice (unchanged tag).
#     landing is stock nginx and deliberately untouched.
if [[ "$REPULL" == "1" ]]; then
  # ns:deploy pairs for the app containers, in restart order.
  for pair in "llamacpp:llamacpp" "chatbot:chatbot"; do
    ns="${pair%%:*}"
    dep="${pair##*:}"
    if kubectl -n "$ns" get deploy "$dep" >/dev/null 2>&1; then
      echo ">> repull: restarting deploy/$dep in $ns"
      kubectl -n "$ns" rollout restart "deploy/$dep"
      kubectl -n "$ns" rollout status "deploy/$dep" --timeout=10m
    else
      echo ">> repull: deploy/$dep not found in $ns — skipping"
    fi
  done
else
  echo ">> REPULL=0 — skipping app container restart"
fi
```

- [ ] **Step 3: Verify Bash syntax**

Run:

```bash
bash -n scripts/faig/deploy.sh
```

Expected: no output, exit code 0 (script parses).

- [ ] **Step 4: Verify the skip path is reachable (static read-through)**

Run:

```bash
grep -nE 'REPULL|rollout restart|rollout status|skipping' scripts/faig/deploy.sh
```

Expected: shows the `REPULL="${REPULL:-1}"` assignment, the `rollout restart`/`rollout status` lines inside the `REPULL == 1` branch, and both skip-notice `echo`s (the `REPULL=0` branch and the missing-deployment branch).

- [ ] **Step 5: Commit**

```bash
git add scripts/faig/deploy.sh
git commit -m "deploy.sh: force repull+restart of llamacpp and chatbot (REPULL=0 to skip)"
```

---

## Manual verification (against a live cluster — not a plan step)

These require a real cluster and are for the operator, not the implementer:

- Default run: `./deploy.sh`, then `kubectl -n llamacpp get pods` and `kubectl -n chatbot get pods` show a recent `AGE` (pods restarted).
- Push a new image to `v1`, `./deploy.sh`, confirm `kubectl -n chatbot get pod -o jsonpath='{..imageID}'` reflects the new digest.
- `REPULL=0 ./deploy.sh` prints `>> REPULL=0 — skipping app container restart` and leaves pod `AGE` unchanged.
- Set `chatbot.enabled: false`, deploy: prints `>> repull: deploy/chatbot not found in chatbot — skipping` and completes with exit 0.

## Self-Review

- **Spec coverage:** values pull-policy change → Task 1. deploy.sh gated repull step with existence guard, ordering, `10m` timeout → Task 2. `REPULL=0` opt-out → Task 2 Step 1. landing untouched → asserted in Task 1 Step 3 render check and Task 2 loop scope. All spec sections covered.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** ns:deploy pairs (`llamacpp:llamacpp`, `chatbot:chatbot`) match the deployment names in the chart templates; `REPULL` name consistent across both steps.
