# Auto-provision a default StorageClass in `deploy.sh`

Date: 2026-07-24
Scope: `scripts/faig/deploy.sh`

## Problem

FortiAIGate (installed separately, after `deploy.sh`) requires "a valid
StorageClass or available PersistentVolumes (if static provisioning is used)".
The target is a single-node, self-managed cluster (control-plane node label,
MetalLB removed, hostNetwork ingress — not AKS), which has no default
StorageClass out of the box. FortiAIGate's PVCs are unqualified (no
`storageClassName`), so they need a **default** StorageClass to bind.

`deploy.sh` should check for this and provision it if absent, so the
separately-installed FortiAIGate has storage ready.

## Approach

Add a `reconcile_storage()` function that mirrors the existing
`reconcile_ingress_nginx()` style: pinned version, idempotent, fail-loud.

- **Detection:** satisfied iff a StorageClass annotated
  `storageclass.kubernetes.io/is-default-class=true` exists. A non-default
  class is NOT sufficient (it won't bind unqualified PVCs).
- **Provisioner:** Rancher local-path-provisioner, applied from its pinned
  release manifest. hostPath-backed dynamic provisioning; the de-facto standard
  for single-node/bare clusters. Then mark its `local-path` class default.
- **Failure mode:** fail-loud (no `|| true`). Unlike the MetalLB *delete* step,
  storage is required — without it FortiAIGate cannot work, so a fetch/apply
  failure must abort the deploy.
- **Toggle:** `PROVISION_STORAGE` (default `1`), opt-out via `0`, matching the
  `REPULL` / `HEALTHCHECK` conventions already in the script.
- **Placement:** a numbered step invoked immediately before the existing
  `reconcile_ingress_nginx` call (~line 188), grouping cluster-prep together.

## Verified facts

- Latest stable release: `v0.0.36` (GitHub releases, checked 2026-07-24).
- Manifest at
  `https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml`
  returns HTTP 200 and creates: namespace `local-path-storage`, Deployment
  `local-path-provisioner`, StorageClass `local-path`. The rollout-status,
  patch, and apply commands below all key off these names.
- The stock manifest does NOT mark `local-path` default — an explicit patch is
  required.

## Implementation

New env vars near the other config block (top of script):

```bash
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.36}"  # rancher local-path-provisioner pin
PROVISION_STORAGE="${PROVISION_STORAGE:-1}"          # set 0 to skip storage reconcile
```

New function:

```bash
reconcile_storage() {
  [[ "$PROVISION_STORAGE" == "0" ]] && { echo ">> PROVISION_STORAGE=0 — skipping storage check"; return 0; }

  # Satisfied iff a DEFAULT StorageClass exists. A non-default class won't bind
  # FortiAIGate's unqualified PVCs, so it does not count.
  if kubectl get storageclass \
       -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
     2>/dev/null | grep -q .; then
    echo ">> default StorageClass present — nothing to provision"
    return 0
  fi

  echo ">> no default StorageClass — installing local-path-provisioner ${LOCAL_PATH_VERSION}"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  echo ">> local-path is now the default StorageClass"
}
```

Call site: a new numbered step immediately before `reconcile_ingress_nginx`.

## Idempotency

- Detection short-circuits when a default class already exists (including a
  re-run after this function created one).
- `kubectl apply` and `kubectl patch` are idempotent.
- Will not create a second default class if a foreign default already exists.

## Out of scope

- Validating the health of a pre-existing foreign default StorageClass — a
  default class is trusted to be valid.
- Static-provisioning (pre-made hostPath PVs) — dynamic provisioning covers the
  requirement with less manual bookkeeping.
- Removing/teardown of local-path-provisioner (belongs in `teardown.sh` if
  wanted later).
