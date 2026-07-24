#!/usr/bin/env bash
# Self-contained deploy of the llm-stack chart to a pre-existing K8s cluster.
# Run from Azure Cloud Shell (or anything with kubectl + helm; az only needed
# if you use the ACR pull-secret step). No Ansible.
#
# Layout assumed:
#   ./llm-stack/     <- the copied chart directory (Chart.yaml lives here)
#   ./values.yaml    <- the self-contained values file
#   ./deploy.sh      <- this script
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- config: override via env, else uses whatever is baked into values.yaml ---
CHART_DIR="${CHART_DIR:-$HERE/llm-stack}"
VALUES="${VALUES:-$HERE/values.yaml}"
RELEASE="${RELEASE:-llm-stack}"
NS_LIST=(llamacpp chatbot landing)

# Optional overrides. If REGISTRY/IMAGE_TAG are set they win over values.yaml,
# so you don't have to edit the file every build. Leave empty to use values.yaml.
REGISTRY="${REGISTRY:-}"          # e.g. myacr.azurecr.io
IMAGE_TAG="${IMAGE_TAG:-}"        # e.g. 2026-07-17
ACR_NAME="${ACR_NAME:-}"          # set to auto-create the acr-pull secret from ACR admin creds

# Force a re-pull + restart of the app containers (llamacpp, chatbot) after the
# helm upgrade so a newly-pushed image on the same tag is picked up. These images
# use imagePullPolicy: Always (values.yaml), so recreating the pod pulls the tag
# fresh. Set REPULL=0 to skip (e.g. when only tweaking landing/config and you
# don't want to pay the llamacpp model reload).
REPULL="${REPULL:-1}"

# End-of-deploy reachability probe of the node IP. Default OFF: the canonical run
# is from Azure Cloud Shell, which can't reach the host's node IP, so the probe
# would false-fail a successful deploy. Set HEALTHCHECK=1 when running on/near the
# host to get the fail-loudly :80/:443 gate.
HEALTHCHECK="${HEALTHCHECK:-0}"

# Storage: FortiAIGate (installed separately) needs a DEFAULT StorageClass that can
# serve ReadWriteMany — its PVCs are unqualified (no storageClassName) and RWX.
# This cluster has no class by default. We install an in-cluster NFS-Ganesha server
# for RWX, itself backed by local-path (RWO, which hostPath does fine).
# Set PROVISION_STORAGE=0 to skip and supply your own RWX default class.
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.36}"   # rancher local-path-provisioner pin
PROVISION_STORAGE="${PROVISION_STORAGE:-1}"
NFS_RELEASE="${NFS_RELEASE:-nfs-server}"
NFS_NS="${NFS_NS:-nfs-server-provisioner}"
NFS_SC_NAME="${NFS_SC_NAME:-nfs}"
NFS_SIZE="${NFS_SIZE:-100Gi}"

apply() { kubectl apply -f - ; }

# LOCAL_IP = the control-plane node's routable IP. Used for the TLS SAN and the
# final URLs. With hostNetwork ingress there is no LoadBalancer IP to wait on —
# the node IP IS the entrypoint.
LOCAL_IP="$(kubectl get node -o wide | awk '/control-plane/{print $6; exit}')"
if [[ -z "$LOCAL_IP" ]]; then
  echo "!! could not determine control-plane node IP" >&2
  exit 1
fi

# 1. Remove MetalLB if present. It hands out a LoadBalancer IP by ARP-ing the
#    node's own address; leaving it up while ingress-nginx binds :80/:443 on that
#    same IP via hostNetwork causes an L2/ARP conflict. Idempotent: a no-op when
#    MetalLB was never installed.
if kubectl get namespace metallb-system >/dev/null 2>&1; then
  echo ">> metallb detected — removing it"
  # Removes what THIS script installed (workloads, CRDs -> cascades the
  # metallb.io pool/advertisement custom resources, RBAC, webhooks).
  # ponytail: || true — a fetch failure (GitHub unreachable) must not abort the
  # migration before the namespace delete below, which is what frees the node IP.
  kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml --ignore-not-found || true
  # ponytail: delete -f is pinned to v0.14.3 (the version we installed). For a
  # FOREIGN install of another version, deleting the namespace still removes its
  # running speaker/controller — which is what actually frees the node IP. Full
  # CRD cleanup of an arbitrary version is out of scope.
  kubectl delete namespace metallb-system --ignore-not-found --wait=false
  # Orphaned cluster-scoped webhook config survives namespace deletion; drop it
  # so it can't later reject metallb.io API calls. Name is stable across versions.
  kubectl delete validatingwebhookconfiguration metallb-webhook-configuration --ignore-not-found
else
  echo ">> metallb not present — nothing to remove"
fi

# 2. Namespaces (the chart does not create them).
for ns in "${NS_LIST[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | apply
done

# 3. ACR pull secret in each namespace — only if ACR_NAME is set.
#    Skip this whole block for public images (also remove imagePullSecrets
#    from values.yaml).
if [[ -n "$ACR_NAME" ]]; then
  echo ">> creating acr-pull secret from ACR admin credentials"
  ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)"
  ACR_USER="$(az acr credential show -n "$ACR_NAME" --query username -o tsv)"
  ACR_PASS="$(az acr credential show -n "$ACR_NAME" --query 'passwords[0].value' -o tsv)"
  REGISTRY="${REGISTRY:-$ACR_LOGIN_SERVER}"   # default registry to the ACR host
  for ns in "${NS_LIST[@]}"; do
    kubectl create secret docker-registry acr-pull \
      --namespace "$ns" \
      --docker-server="$ACR_LOGIN_SERVER" \
      --docker-username="$ACR_USER" \
      --docker-password="$ACR_PASS" \
      --dry-run=client -o yaml | apply
  done
fi

# Self-signed TLS cert for the ingress HTTPS listener (lab-grade — browsers warn
# on the self-signed issuer). Created ONCE per namespace and reused: regenerating
# would roll the controller. SAN covers the node IP (the entrypoint).
ensure_landing_tls() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | apply
  if kubectl -n "$ns" get secret landing-tls >/dev/null 2>&1; then
    echo ">> landing-tls already exists in $ns — reusing it"
    return 0
  fi
  echo ">> generating self-signed landing-tls in $ns (SAN=IP:${LOCAL_IP})"
  local cert_dir
  cert_dir="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$cert_dir/tls.key" -out "$cert_dir/tls.crt" \
    -subj "/CN=${LOCAL_IP}" -addext "subjectAltName=IP:${LOCAL_IP}"
  kubectl -n "$ns" create secret tls landing-tls \
    --cert="$cert_dir/tls.crt" --key="$cert_dir/tls.key"
  rm -rf "$cert_dir"
}

INGRESS_CHART_VERSION="${INGRESS_CHART_VERSION:-4.11.3}"   # ingress-nginx chart pin

install_ingress_ours() {
  echo ">> installing ingress-nginx (helm, hostNetwork) into ns ingress-nginx"
  ensure_landing_tls ingress-nginx
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update ingress-nginx >/dev/null
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --version "$INGRESS_CHART_VERSION" \
    --set controller.hostNetwork=true \
    --set controller.dnsPolicy=ClusterFirstWithHostNet \
    --set controller.service.type=ClusterIP \
    --set controller.extraArgs.default-ssl-certificate=ingress-nginx/landing-tls \
    --wait --timeout 5m
}

patch_ingress_foreign() {
  # $1=kind $2=name $3=namespace of an existing (non-ours) controller workload.
  local kind="$1" name="$2" ns="$3"
  echo "!! WARNING: modifying a pre-existing ingress-nginx controller ($kind/$name in $ns)"
  ensure_landing_tls "$ns"
  # hostNetwork + dnsPolicy so it binds the node ports.
  if [[ "$(kubectl -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.template.spec.hostNetwork}')" != "true" ]]; then
    echo ">> patching $kind/$name to hostNetwork"
    kubectl -n "$ns" patch "$kind" "$name" --type=merge \
      -p '{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}'
  fi
  # Ensure --default-ssl-certificate is on the controller container args.
  if ! kubectl -n "$ns" get "$kind" "$name" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="controller")].args}' \
        | grep -q -- '--default-ssl-certificate'; then
    echo ">> patching $kind/$name to add --default-ssl-certificate=$ns/landing-tls"
    local cline cidx
    cline="$(kubectl -n "$ns" get "$kind" "$name" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' \
      | grep -nx controller | cut -d: -f1 || true)"
    if [[ -z "$cline" ]]; then
      echo "!! $kind/$name has no container named 'controller' — cannot add --default-ssl-certificate; aborting to avoid a half-patched controller" >&2
      exit 1
    fi
    cidx=$((cline - 1))
    kubectl -n "$ns" patch "$kind" "$name" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${cidx}/args/-\",\"value\":\"--default-ssl-certificate=${ns}/landing-tls\"}]"
  fi
  kubectl -n "$ns" rollout status "$kind/$name" --timeout=180s
}

# Smoke-test the default StorageClass by actually binding an RWX PVC and mounting
# it. This is the only honest check: a StorageClass advertises no access modes, so
# "a default class exists" says nothing about RWX (local-path has a default class
# and cannot do RWX — that is the exact failure this guards). Also catches nodes
# missing nfs-common/nfs-utils, where the PVC binds but the mount hangs forever.
verify_rwx() {
  local ns="$1" ok=0
  kubectl -n "$ns" delete pod/rwx-probe pvc/rwx-probe --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$ns" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: rwx-probe}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: rwx-probe}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.36
      command: [sh, -c, "touch /data/ok && sleep 3"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes:
    - name: d
      persistentVolumeClaim: {claimName: rwx-probe}
EOF
  kubectl -n "$ns" wait --for=condition=Ready pod/rwx-probe --timeout=180s >/dev/null 2>&1 && ok=1
  [[ "$ok" == "1" ]] || kubectl -n "$ns" describe pod/rwx-probe | tail -20 >&2
  kubectl -n "$ns" delete pod/rwx-probe pvc/rwx-probe --ignore-not-found >/dev/null 2>&1 || true
  return $((1 - ok))
}

reconcile_storage() {
  [[ "$PROVISION_STORAGE" == "0" ]] && { echo ">> PROVISION_STORAGE=0 — skipping storage check"; return 0; }

  # FortiAIGate's PVCs are unqualified (no storageClassName) AND ReadWriteMany, so
  # the cluster needs a DEFAULT class that can serve RWX. hostPath provisioners
  # (local-path) cannot: "NodePath only supports ReadWriteOnce and ReadWriteOncePod".
  local default_sc
  default_sc="$(kubectl get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1)"

  if [[ -n "$default_sc" && "$default_sc" != "local-path" ]]; then
    echo ">> default StorageClass '$default_sc' present — verifying it serves RWX"
    verify_rwx default && { echo ">> '$default_sc' serves RWX — nothing to provision"; return 0; }
    echo "!! default StorageClass '$default_sc' cannot serve a ReadWriteMany PVC." >&2
    echo "!! FortiAIGate needs RWX. Remove its default annotation and re-run, or set PROVISION_STORAGE=0" >&2
    echo "!! and provide an RWX default class yourself." >&2
    exit 1
  fi

  # local-path backs the NFS server's OWN volume (that claim is RWO, which
  # local-path handles fine). It must NOT be the default class — FortiAIGate would
  # land on it and fail. Idempotent: apply is a no-op when already present.
  echo ">> installing local-path-provisioner ${LOCAL_PATH_VERSION} (backing store for the NFS server)"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
  # Strip the default annotation an earlier run of this script may have set. Two
  # default classes is undefined behaviour; local-path as the default is the bug.
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

  # NFS-Ganesha runs the server in userspace inside the cluster, so no external NFS
  # box and no host nfsd. Nodes DO still need an NFS client (nfs-common on Debian/
  # Ubuntu, nfs-utils on RHEL) for the kubelet to mount the export — verify_rwx
  # below is what catches its absence.
  echo ">> installing nfs-server-provisioner (RWX default StorageClass '${NFS_SC_NAME}')"
  helm repo add nfs-ganesha-server-and-external-provisioner \
    https://kubernetes-sigs.github.io/nfs-ganesha-server-and-external-provisioner/ >/dev/null 2>&1 || true
  helm repo update nfs-ganesha-server-and-external-provisioner >/dev/null
  helm upgrade --install "$NFS_RELEASE" \
    nfs-ganesha-server-and-external-provisioner/nfs-server-provisioner \
    --namespace "$NFS_NS" --create-namespace \
    --set persistence.enabled=true \
    --set persistence.storageClass=local-path \
    --set "persistence.size=${NFS_SIZE}" \
    --set "storageClass.name=${NFS_SC_NAME}" \
    --set storageClass.defaultClass=true \
    --wait --timeout 5m

  verify_rwx default || {
    echo "!! RWX probe failed after installing the NFS provisioner." >&2
    echo "!! Most likely the nodes lack an NFS client. On each node:" >&2
    echo "!!   Ubuntu/Debian: sudo apt-get install -y nfs-common" >&2
    echo "!!   RHEL/Rocky:    sudo dnf install -y nfs-utils" >&2
    exit 1
  }
  echo ">> '${NFS_SC_NAME}' is the default StorageClass and serves RWX"
}

reconcile_ingress_nginx() {
  # 1. Our own helm release?
  if helm status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then
    echo ">> ingress-nginx (our helm release) present — upgrading to reconcile config"
    install_ingress_ours   # helm upgrade --install is idempotent; repairs drift
    return 0
  fi
  # 2. A foreign controller anywhere?
  local line
  line="$(kubectl get deploy,daemonset -A \
    -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller \
    -o jsonpath='{.items[0].kind}|{.items[0].metadata.name}|{.items[0].metadata.namespace}' 2>/dev/null || true)"
  if [[ -n "$line" && "$line" != "||" ]]; then
    IFS='|' read -r k n ns <<<"$line"
    patch_ingress_foreign "$k" "$n" "$ns"
    return 0
  fi
  # 3. Nothing installed.
  install_ingress_ours
}

# Ensure an RWX-capable default StorageClass exists before FortiAIGate (installed
# separately) needs it. No-op when the cluster already has one that passes the probe.
reconcile_storage

# Ensure a correctly-exposed nginx ingress controller exists before the workload
# (its Ingress resources need a controller to bind to).
reconcile_ingress_nginx

# 4. Install / upgrade. Only pass --set for values that were overridden via env.
SET_ARGS=()
if [[ -n "$REGISTRY" ]]; then
  SET_ARGS+=(--set "llamacpp.image.repository=$REGISTRY/llamacpp"
             --set "chatbot.image.repository=$REGISTRY/chatbot"
             --set "landing.image.repository=$REGISTRY/nginx")
fi
[[ -n "$IMAGE_TAG" ]] && SET_ARGS+=(--set "global.imageTag=$IMAGE_TAG")

echo ">> helm upgrade --install $RELEASE"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -f "$VALUES" \
  "${SET_ARGS[@]}" \
  --namespace llamacpp \
  --wait --timeout 10m

# 4b. Force llamacpp + chatbot to re-pull and restart so a newly-pushed image on
#     the same tag is picked up. helm upgrade alone won't notice (unchanged tag).
#     landing is stock nginx and deliberately untouched.
if [[ "$REPULL" != "0" ]]; then
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

# 5. Health gate (opt-in): with hostNetwork the node IP IS the entrypoint. Prove
#    the controller is bound before declaring success — check :80 (HTTP bind) AND
#    :443 (every advertised URL is https, so a missing/broken default cert must
#    fail the lab HERE, not in a student's browser). Any HTTP status (even 404)
#    proves the listener; a connection refusal does not. -k on https because the
#    cert is self-signed. Default OFF (HEALTHCHECK): unreachable from Cloud Shell.
if [[ "$HEALTHCHECK" != "0" ]]; then
  echo ">> health check: http://${LOCAL_IP}/ and https://${LOCAL_IP}/"
  gate_ok=""
  http_code=""; https_code=""
  for _ in $(seq 1 30); do
    http_code="$(curl -s  -o /dev/null -w '%{http_code}' "http://${LOCAL_IP}/"  2>/dev/null || true)"
    https_code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${LOCAL_IP}/" 2>/dev/null || true)"
    if [[ "$http_code" =~ ^[1-5][0-9][0-9]$ && "$https_code" =~ ^[1-5][0-9][0-9]$ ]]; then
      gate_ok="1"; break
    fi
    sleep 2
  done
  if [[ -z "$gate_ok" ]]; then
    echo "!! ingress controller not answering on both http://${LOCAL_IP}/ and https://${LOCAL_IP}/ — the lab will not work." >&2
    echo "!! last codes: http='${http_code}' https='${https_code}'" >&2
    echo "!! diagnose: kubectl get pods -A -l app.kubernetes.io/component=controller -o wide" >&2
    exit 1
  fi
else
  echo ">> HEALTHCHECK=0 — skipping node-IP reachability probe (set HEALTHCHECK=1 to enable)"
fi

cat <<EOF

>> Deployed. 

   FortiAIGate (installed separately) attaches its own Ingress for /ui, /v1/...,
   and the '/' catch-all against IngressClass nginx.
EOF
