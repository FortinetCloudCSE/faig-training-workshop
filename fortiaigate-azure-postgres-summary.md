# FortiAIGate Azure Workshop: NFS/PostgreSQL Startup Incident

Original incident: 2026-08-18  
Live follow-up test: 2026-08-19

## Artifacts and deployment flow reviewed

This report was revalidated against the exact workshop artifacts downloaded on 2026-08-18:

- `FAIG_helm_chart-V8.0.1-build0031-FORTINET.tar` (`sha256:606b45f6ba5f25a7d4c5c021cfd4223eaa5a3444d267d2da7dfe7ad5b5b26993`)
- The separately distributed FortiAIGate `values.yaml` (`sha256:b5334deecb0a20cd13e22466cfca768fb1474a750bd2baf4e55ee0932b040c54`)
- `faig-training-workshop/scripts/faig/deploy.sh`

The script does not install FortiAIGate itself. It installs the CPU-only LLM/chatbot/landing stack, ingress-nginx, `local-path`, and the NFS-Ganesha RWX provisioner. The workshop then extracts the tar archive to `$HOME/fortiaigate` and installs FortiAIGate separately with:

```bash
helm install fortiaigate ./fortiaigate -n fortiaigate -f values.yaml
```

The downloaded override selects the `node-worker` license, the workshop ACR images, CPU-only mode, and a larger Triton CPU limit. It does not override PostgreSQL/Redis storage, probes, or credentials. The archive's database-related templates and bundled PostgreSQL/Redis subcharts match those analyzed for this incident; differences from another local build0031 copy were confined to non-database areas such as ingress, licensing, TLS, Triton, and defaults.

## Executive summary

A new FortiAIGate 8.0.1 installation on the Azure kubeadm workshop cluster failed because its in-cluster NFS service became non-responsive. PostgreSQL was configured to store its database on the same NFS-backed RWX claim used by FortiAIGate application services and Redis. Slow or stalled NFS I/O caused PostgreSQL's first-time initialization to exceed the chart's liveness window. Kubernetes killed the container after part of the data directory had been created, and the next start incorrectly treated that partial directory as an initialized database.

API, core, and logd then reached PostgreSQL but received password-authentication failures because database user/password initialization had never completed. The same NFS outage later prevented API, core, logd, and license-manager from mounting their shared application volume, even though the NFS pod itself reported Ready.

The deployment was recovered by:

1. Moving PostgreSQL and Redis to dedicated RWO `local-path` volumes for this single-worker lab.
2. Enabling a long PostgreSQL startup probe so liveness cannot interrupt initial bootstrap.
3. Removing stale terminating StatefulSet pods and reconciling their replicas.
4. Restarting the NFS-Ganesha pod, after which all remaining shared-volume mounts succeeded and every FortiAIGate pod became Running.

This was not caused by reuse of an old database or an independently regenerated Secret. Resource timestamps and Helm history showed a revision-one installation with a newly created Secret, PVC, pod, and PostgreSQL data directory.

A live follow-up deployment on 2026-08-19 did not reproduce the complete NFS outage, but it did independently reproduce large, transient NFS latency changes while FortiAIGate pods and images were starting. NFS-backed probe-pod startup rose from a normal 1-3 seconds to 23-33 seconds before recovering, and NFS client statistics showed elevated RPC round-trip and total execution times during active samples. This reinforces using dedicated `local-path` volumes for PostgreSQL and Redis on every workshop installation rather than reserving that configuration only as a recovery measure.

## Original symptoms

The API, core, and logd containers all failed during startup with the same Prisma error:

```text
P1000: Authentication failed against database server at
`fortiaigate-postgresql`; credentials for
`fortiaigate_postgres_user` are not valid.
```

Each service attempted `prisma migrate deploy`, exhausted four retries, failed its database/global-state initialization, and exited. PostgreSQL was reachable, which distinguished this from DNS or connection-refused failures, but both the application user password and the Secret's PostgreSQL administrator password failed authentication.

## Evidence and root cause

The initial release resources were all created at approximately 21:04 UTC. PostgreSQL created `/bitnami/postgresql/data/PG_VERSION` at 21:11:54. The first PostgreSQL container then exited with code 137 after beginning initialization:

```text
21:11:54 Starting PostgreSQL setup
21:11:54 Initializing PostgreSQL database
21:13:21 Starting PostgreSQL in background
```

The pod had one restart and Kubernetes reported exit code 137. On the next start, Bitnami logged `Deploying PostgreSQL with persisted data`, because `PG_VERSION` existed, but the first bootstrap had not finished assigning passwords and preparing the configured database. PostgreSQL subsequently reported that the `postgres` role had no password assigned.

The chart had PostgreSQL liveness enabled with a 30-second initial delay and six failures at ten-second intervals, but no startup probe. This gives initialization only about 90 seconds before kubelet termination. The observed timing matched that window.

A second clean attempt with a ten-minute startup probe also ended with exit code 137 after 54 startup-probe failures. PostgreSQL remained at `Initializing PostgreSQL database` for the entire interval. This established that the shared NFS path was not providing acceptable initialization behavior.

After PostgreSQL and Redis were moved off NFS, both started successfully. The remaining application pods exposed the underlying storage failure directly:

```text
MountVolume.SetUp failed ...
mount -t nfs ... 10.x.x.x:/export/pvc-...
mount.nfs: Connection timed out
```

The NFS-Ganesha pod showed `1/1 Running` and its Service had endpoints, but the worker could not mount the export through the Service IP. Restarting that pod immediately restored the mounts and allowed API, core, logd, and license-manager to start. The evidence therefore strongly identifies non-responsive NFS as the initiating failure. The chart's shared-storage and probe design amplified a transient NFS problem into a persistent PostgreSQL bootstrap/authentication failure.

## Recovery applied

The effective recovery overlay was equivalent to:

```yaml
postgresql:
  volumePermissions:
    enabled: true
  primary:
    startupProbe:
      enabled: true
      initialDelaySeconds: 30
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 180
    persistence:
      enabled: true
      existingClaim: ""
      storageClass: local-path
      accessModes: [ReadWriteOnce]
      size: 16Gi

redis:
  master:
    persistence:
      enabled: true
      existingClaim: ""
      storageClass: local-path
      accessModes: [ReadWriteOnce]
      size: 4Gi
```

`fortiaigate-storage` remained an NFS-backed RWX claim for application data that must be shared. `local-path` is suitable for this disposable, single-worker workshop but is not a production durability or high-availability recommendation.

## Workshop deployment policy and mid-workshop recovery

For this workshop topology, the overlay above should be distributed as a versioned file such as `fortiaigate-local-db.yaml` and applied on **every** FortiAIGate installation:

```bash
helm upgrade --install fortiaigate ./fortiaigate \
  -n fortiaigate --create-namespace \
  -f values.yaml \
  -f fortiaigate-local-db.yaml \
  --wait --timeout 30m
```

This does not replace NFS with `local-path` globally. The intended storage split is:

- `fortiaigate-storage`: NFS, RWX, for application data that must be shared by multiple pods.
- PostgreSQL: its own `local-path`, RWO claim.
- Redis: its own `local-path`, RWO claim.

Changing the default StorageClass to `local-path` or moving every claim to it is not a valid fallback because the shared `fortiaigate-storage` claim requests RWX, which `local-path` cannot provide.

If a new workshop installation has already failed, it is not necessary to reprovision the Azure VMs or Kubernetes cluster. A prepared mid-workshop recovery can uninstall only the FortiAIGate release, delete and recreate the `fortiaigate` namespace so the partial database and generated credential Secret are removed together, and reinstall with both values files. This is appropriate only for a failed, new workshop installation with no data to preserve. The instructor should first retain PostgreSQL current/previous logs, pod state, and events; namespace deletion should not be force-finalized if it stalls.

The recovery decision should not be based on `P1000` alone. The high-confidence incident signature is a revision-one installation in which PostgreSQL begins first-time initialization, restarts with exit code 137, then reports persisted data and is followed by the API/core/logd authentication errors recorded in `postgres-startup-errors.txt`. A standalone authentication error without that sequence may have a different cause.
