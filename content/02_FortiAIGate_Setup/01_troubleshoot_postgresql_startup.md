---
title: "Troubleshooting PostgreSQL Startup"
linkTitle: "Troubleshooting Startup"
weight: 110
---

## When to Use This Page

Use this procedure when a new FortiAIGate installation remains unhealthy and `api`, `core`, or `logd` reports:

```text
P1000: Authentication failed against database server at `fortiaigate-postgresql`
```

{{% notice style="warning" title="New Workshop Installations Only" %}}
This recovery deletes the failed FortiAIGate installation and its stored data. Use it only for a new workshop installation with no data to preserve. A `P1000` message by itself is not enough to identify this incident.
{{% /notice %}}

## 1. Confirm This Failure

Run the following in Azure Cloud Shell:

```bash
PG_POD=$(kubectl -n fortiaigate get pods \
  -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n fortiaigate get pod "$PG_POD" -o json | jq \
  '.status.containerStatuses[] | {name, restartCount, state, lastState}'

kubectl -n fortiaigate logs "$PG_POD" --previous --timestamps --tail=200 \
  2>/dev/null | grep -E 'Initializing PostgreSQL|Starting PostgreSQL in background'

kubectl -n fortiaigate logs "$PG_POD" --timestamps --tail=200 \
  | grep -E 'persisted data|no password assigned'

for service in api core logd; do
  kubectl -n fortiaigate logs "deployment/$service" --tail=100 2>/dev/null \
    | grep -m1 'P1000' && echo "Found in $service"
done
```

This is likely the NFS/PostgreSQL initialization incident when all of these are true:

- PostgreSQL started first-time initialization and then restarted.
- Its previous exit code was `137`.
- Its next start reported persisted data.
- API, core, or logd reports `P1000`.

The password error is a symptom: slow NFS interrupted initialization before PostgreSQL finished assigning credentials. Do not fix it by changing only the Kubernetes Secret.

If PostgreSQL did not restart with exit code 137, stop here and ask the instructor to investigate a different cause.

## 2. Check for a Current NFS Mount Failure

```bash
kubectl get events -A --sort-by=.metadata.creationTimestamp \
  | grep -Ei 'FailedMount|mount.nfs|Connection timed out' \
  | tail -n 30
```

If this shows `mount.nfs: Connection timed out`, tell the instructor. PostgreSQL and Redis will be moved off NFS below, but FortiAIGate still requires NFS for its shared RWX application volume.

## 3. Remove the Failed Installation

```bash
helm uninstall fortiaigate -n fortiaigate --wait --timeout 10m

kubectl delete namespace fortiaigate --wait=true --timeout=10m

kubectl create namespace fortiaigate
```

If uninstall or namespace deletion times out, do not force it. Ask the instructor to check for terminating pods or volumes.

If Step 2 showed an NFS connection timeout, restart NFS-Ganesha before reinstalling:

```bash
NFS_STS=$(kubectl -n nfs-server-provisioner get statefulset \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n nfs-server-provisioner rollout restart "statefulset/$NFS_STS"

kubectl -n nfs-server-provisioner rollout status "statefulset/$NFS_STS" \
  --timeout=5m
```

## 4. Reinstall with Local Database Storage

Confirm that the workshop overlay is available:

```bash
test -f "$HOME/faig-training-workshop/scripts/faig/fortiaigate-local-db.yaml" \
  && echo "Storage overlay found"
```

Then reinstall FortiAIGate:

```bash
cd "$HOME"

helm upgrade --install fortiaigate ./fortiaigate \
  -n fortiaigate --create-namespace \
  -f values.yaml \
  -f "$HOME/faig-training-workshop/scripts/faig/fortiaigate-local-db.yaml" \
  --wait --timeout 30m
```

This keeps the shared `fortiaigate-storage` claim on NFS while moving only PostgreSQL and Redis to dedicated `local-path` claims. The overlay also gives PostgreSQL a longer startup window.

## 5. Verify the Recovery

```bash
kubectl -n fortiaigate get pvc \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,MODES:.spec.accessModes[*],STATUS:.status.phase'

kubectl -n fortiaigate get pods
```

Verify that:

- The PostgreSQL and Redis claims use `local-path` and `ReadWriteOnce`.
- `fortiaigate-storage` uses `nfs` and `ReadWriteMany`.
- All FortiAIGate pods eventually show `Running` and `1/1` Ready.
- PostgreSQL has not restarted again.

{{% notice style="green" icon="hand-point-right" title="Recovery Complete" %}}
After all pods are Ready, return to [Installing FortiAIGate]({{< relref "02_FortiAIGate_Setup" >}}) and continue with the WebUI verification.
{{% /notice %}}
