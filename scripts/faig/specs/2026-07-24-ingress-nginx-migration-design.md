# Deploy: migrate from MetalLB to ingress-nginx

**Date:** 2026-07-24
**Scope:** `scripts/faig/deploy.sh`, `scripts/faig/values.yaml`, `scripts/faig/llm-stack/templates/landing/*`, new Ingress templates.

## Problem

`deploy.sh` currently deploys **MetalLB** to hand the `landing` Service a
bare-metal `LoadBalancer` IP (the control-plane node's own routable IP, `/32`),
and the `landing` nginx pod acts as the single reverse proxy for every route:

- `/` → static landing page (served in-pod)
- `/chat/` → chatbot Service (Streamlit, websockets)
- `/llm/` → llamacpp Service (llama-server, prefix stripped)

**FortiAIGate** will be installed **later** (not by this chart). It needs to
interface with the standard **nginx ingress controller**: its main UI lives at
`/ui`, plus API endpoints at other paths (e.g. `/v1/foo/bar`). The desired end
state routing:

- `/` (bare root only) → landing pod
- `/chat` → chatbot (keep)
- `/llm` → llamacpp (keep)
- everything else → FortiAIGate

MetalLB is to be **removed completely** in favour of the intended nginx ingress
controller. The script must **detect** whether an nginx ingress controller is
already installed and, if not, install it — and because this is a training lab,
it must also **repair** a misconfigured existing controller so the lab works.

## Decisions (from brainstorming)

| Decision | Choice | Rationale |
|-|-|-|
| Ingress exposure (no MetalLB) | `hostNetwork` on `:80`/`:443` | Single-node/control-plane Azure VM, no cloud LB. Keeps clean `http(s)://<node-IP>/` URLs without any LB IP allocator. |
| FortiAIGate routes | FortiAIGate owns its own Ingress | Installed later; no dangling backend to a non-existent Service. This deploy only wires `/`, `/chat`, `/llm`. |
| TLS termination | At the ingress, reuse existing self-signed cert | Move the self-signed cert (SAN = node IP) into the `ingress-nginx` namespace once; set it as the controller's `--default-ssl-certificate`. Landing pod stops terminating TLS. |
| Install method | Helm chart (`ingress-nginx/ingress-nginx`) | Clean flag-based `hostNetwork`, idempotent, matches existing helm usage in this repo. |
| Existing controller | Verify **and repair** in place (incl. foreign installs) | Lab must work; a misconfigured controller is patched, never left broken. Never refuse on a foreign controller. |

## Architecture

**Before:** MetalLB → `landing` Service (`LoadBalancer`, node IP `/32`) →
`landing` nginx pod reverse-proxies `/`, `/chat`, `/llm`.

**After:** ingress-nginx controller (hostNetwork, binds node `:80`/`:443`) →
routes via Ingress resources. `landing` pod becomes a plain HTTP static server
(`ClusterIP`). MetalLB removed entirely.

```
node:80/443 ──> ingress-nginx (hostNetwork, default-ssl-certificate=ingress-nginx/landing-tls)
   ├─ /        (Exact)  ──> landing   svc  (landing ns)
   ├─ /chat    (Prefix) ──> chatbot   svc  (chatbot ns)   [websocket, long timeout]
   ├─ /llm/... (regex)  ──> llamacpp  svc  (llamacpp ns)  [strip /llm, body size 0]
   └─ /        (Prefix, catch-all) ──> FortiAIGate  [added later, by FortiAIGate itself]
```

**Path precedence** is resolved natively by ingress-nginx across separate
Ingress resources: `/` `Exact` beats `/` `Prefix` for the bare root, so the
landing page owns exactly `/`; `/chat` and `/llm` are longer prefixes so they
beat FortiAIGate's future `/` catch-all; everything else falls through to
FortiAIGate.

## Components changed

### 1. `deploy.sh`

**Remove** the entire MetalLB *install* block: install, `IPAddressPool`,
`L2Advertisement`, and the webhook-retry loop (current lines ~34–88), plus the
`LOCAL_IP`-derived MetalLB pool logic used only for MetalLB.

**Add** an active MetalLB *teardown* step (see "MetalLB teardown" below) — a
cluster that ran the old script already has MetalLB, and leaving it up while
ingress-nginx claims the same node IP via hostNetwork invites an ARP/L2
advertisement conflict over that IP. Teardown runs **first**, before the
ingress-nginx reconcile.

**Keep** `LOCAL_IP` (control-plane node IP) — still needed for the TLS SAN and
for printing/curl-checking the final URLs.

**Add** an ingress-nginx reconcile step (see "Ingress-nginx reconciliation"
below) run **before** the workload install, so Ingress resources have a
controller to bind to.

**Move** the self-signed TLS secret from the `landing` namespace to the
`ingress-nginx` namespace (or to the foreign controller's namespace — see
repair), same generate-once logic, same node-IP SAN. Referenced by the
controller via `--default-ssl-certificate`.

**Simplify** the final URL step: with hostNetwork, the entrypoint is `LOCAL_IP`
directly — drop the "wait for LoadBalancer ingress IP" loop. Print:

```
Landing : https://<LOCAL_IP>/
Chatbot : https://<LOCAL_IP>/chat/
LLM API : https://<LOCAL_IP>/llm/v1/models
```

`NS_LIST` keeps `landing`/`chatbot`/`llamacpp`; the `ingress-nginx` namespace is
created by helm (`--create-namespace`).

### 2. MetalLB teardown (the "remove if detected" requirement)

Runs before the ingress-nginx reconcile so the node IP is free by the time the
new controller binds it. Idempotent — a no-op on a cluster that never had
MetalLB.

Detect by the `metallb-system` namespace (mirrors the old presence check).
If absent → skip, log `>> metallb not present — nothing to remove`.
If present → remove:

1. `kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml --ignore-not-found`
   — cleanly removes what *this* script installed (workloads, CRDs — which
   cascade-delete the `IPAddressPool`/`L2Advertisement` CRs — RBAC, and the
   webhook configurations).
2. `kubectl delete namespace metallb-system --ignore-not-found --wait=false`
   — belt-and-suspenders for a **foreign** MetalLB install (installed by other
   means / a different version) whose workloads the pinned manifest above did
   not match by name.
3. `kubectl delete validatingwebhookconfiguration metallb-webhook-configuration --ignore-not-found`
   — drop any orphaned webhook config (cluster-scoped, survives namespace
   deletion) so it can't block later `metallb.io` API calls. The name is stable
   across MetalLB versions.

**Known ceiling (`ponytail:` comment):** the `delete -f` URL is pinned to
`v0.14.3` (the version this script installed). A foreign install of a *different*
version has its cluster-scoped CRDs removed only insofar as their names match;
the namespace delete (step 2) still removes its running speaker/controller, which
is what actually frees the node IP. Full CRD cleanup of an arbitrary foreign
version is out of scope — deleting the workloads is sufficient to avoid the L2
conflict.

### 3. Ingress-nginx reconciliation (the "detect / repair" requirement)

Locate the controller workload (Deployment **or** DaemonSet) cluster-wide by the
standard labels
`app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller`,
then branch:

1. **No controller found** → `helm upgrade --install ingress-nginx
   ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace` with:
   - `controller.hostNetwork=true`
   - `controller.dnsPolicy=ClusterFirstWithHostNet`
   - `controller.service.type=ClusterIP`
   - `controller.extraArgs.default-ssl-certificate=ingress-nginx/landing-tls`
     (the TLS secret is created in `ingress-nginx` before the install).

2. **Controller is our helm release** (release `ingress-nginx` in ns
   `ingress-nginx`) → `helm upgrade` with the same values. Idempotent; repairs
   config drift for free.

3. **Controller is foreign** (an `nginx` IngressClass / controller exists but is
   not our release — base-image install, raw manifest, or a different
   namespace) → **patch in place** (never refuse):
   - Ensure the `landing-tls` secret exists in *that* controller's namespace.
   - `kubectl patch` the workload pod spec: `hostNetwork: true` +
     `dnsPolicy: ClusterFirstWithHostNet` if not already set.
   - Ensure `--default-ssl-certificate=<ctrl-ns>/landing-tls` is present in the
     controller container args (patch it in if missing).
   - `kubectl -n <ctrl-ns> rollout status` the workload.
   - Emit a clear warning that a pre-existing controller was modified.

4. **Post-reconcile health gate** (all branches): confirm the controller pod is
   `Ready` and the node answers on `:80` — a quick `curl -sk
   http://$LOCAL_IP/` returning *any* HTTP status (even 404) proves the bind.
   If it does not, **fail loudly** with the diagnostic command to run, rather
   than proceeding to a lab that silently will not work.

**Known ceilings (documented in `ponytail:` comments, not fixed here):**
- A foreign controller under active management (its own Helm/operator) may
  revert the patch on its next reconcile. Acceptable for a static lab cluster.
- If the foreign controller already binds `:80`/`:443` via a *different*
  exposure (NodePort/its own LB), the hostNetwork patch can collide; the health
  gate catches this and fails loudly rather than half-fixing.

### 4. `values.yaml` + chart

- `landing.service.type` → `ClusterIP` (drop `LoadBalancer`).
- Remove `landing.tls` (the pod no longer terminates TLS).
- `landing/nginx-config.yaml` → strip the `/chat` and `/llm` `proxy_pass`
  blocks and the `443`/`ssl` listener; keep only the static `/` server on `:80`.
- `landing/deployment.yaml` and `landing/service.yaml` → drop the `443`
  container port, the TLS volume, and the TLS volumeMount.
- **New Ingress templates**, one per component (each in its component's
  namespace so the Ingress is co-located with its Service; `ingressClassName:
  nginx`; **no `host`** so any host / raw-IP access matches):
  - `templates/landing/ingress.yaml` — path `/`, `pathType: Exact` → landing
    svc `:{{ .Values.landing.service.port }}`.
  - `templates/chatbot/ingress.yaml` — path `/chat`, `pathType: Prefix` →
    chatbot svc; annotation
    `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` (Streamlit
    websockets + long-lived streams; ingress-nginx auto-upgrades websockets).
    Prefix is **preserved** (Streamlit `baseUrlPath=/chat`).
  - `templates/llamacpp/ingress.yaml` — path `/llm(/|$)(.*)` with annotations
    `nginx.ingress.kubernetes.io/use-regex: "true"`,
    `nginx.ingress.kubernetes.io/rewrite-target: /$2`,
    `nginx.ingress.kubernetes.io/proxy-body-size: "0"`,
    `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` → llamacpp svc.
    Strips the `/llm` prefix, matching today's `proxy_pass .../` behaviour
    (llama-server expects `/v1/...`).

Rewrite-target and `use-regex` are per-Ingress-resource annotations, which is
why `/llm` (needs strip) and `/chat` (must **not** be stripped) are separate
Ingress resources rather than paths on one Ingress.

## What this deploy does NOT do

FortiAIGate's `/ui`, `/v1/...`, and the `/` catch-all are **not** created here.
FortiAIGate registers its own Ingress against the `nginx` class when installed
later. This deploy only guarantees the controller exists, is correctly exposed,
and that the `/`, `/chat`, `/llm` routes work.

## Error handling / edge cases

- Runs under `set -euo pipefail`; the ingress-nginx reconcile is guarded so
  reruns are idempotent (helm upgrade for our release; patch is a no-op when the
  workload already has the required fields).
- TLS secret generated **once**, reused across runs (regenerating would roll the
  controller needlessly).
- Health gate is the backstop for every failure mode above — no silent
  half-configured lab.

## Verification

- `bash -n deploy.sh` (no shellcheck in this environment).
- Confirm the MetalLB teardown and ingress reconcile use `--ignore-not-found`
  / presence guards so a rerun (MetalLB already gone, controller already
  correct) is a clean no-op under `set -euo pipefail`.
- `helm template` the chart → confirm the three Ingress resources render with
  correct paths, `pathType`, `ingressClassName`, and annotations; landing
  renders `ClusterIP` with no `443`/TLS.
- `helm lint` the chart.
- `helm template`/dry-run the ingress-nginx values to confirm `hostNetwork` and
  `default-ssl-certificate` are set.
