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

apply() { kubectl apply -f - ; }

# 1. MetalLB — bare-metal LoadBalancer provider. Install only if absent.
#    This runs BEFORE the workload so type:LoadBalancer Services get an IP.
if kubectl -n metallb-system rollout status deploy/controller --timeout=1s >/dev/null 2>&1; then
  echo ">> metallb present — reusing it"
else
  echo ">> installing metallb v0.14.3"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
  kubectl -n metallb-system rollout status deploy/controller --timeout=180s
  kubectl -n metallb-system rollout status ds/speaker --timeout=180s
fi

# 1b. Reconcile the IP pool on EVERY run (idempotent), not only on first install.
#     A redeploy that reuses MetalLB must still repair a missing/stale pool, or a
#     type:LoadBalancer Service gets stuck <pending> with "no available IPs".
# ponytail: /32 = exactly one address — the node's own routable IP (Azure L2
#     won't ARP any other VNet address). Only ONE LoadBalancer Service can bind
#     it; a second competing LB Service stays pending. That's an infra ceiling,
#     not fixable here — don't add a second LB Service to this cluster.
LOCAL_IP="$(kubectl get node -o wide | awk '/control-plane/{print $6; exit}')"
if [[ -z "$LOCAL_IP" ]]; then
  echo "!! could not determine control-plane node IP" >&2
  exit 1
fi
echo ">> metallb pool = ${LOCAL_IP}/32"
# The validating webhook may not be serving yet right after a fresh controller
# rollout, so retry the pool apply a few times before giving up.
pool_applied=""
for attempt in $(seq 1 10); do
  if kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LOCAL_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
EOF
  then
    pool_applied="1"
    break
  fi
  echo ">> IPAddressPool apply failed (attempt ${attempt}/10) — webhook may not be ready yet, retrying in 5s"
  sleep 5
done
if [[ -z "$pool_applied" ]]; then
  echo "!! failed to apply MetalLB IPAddressPool/L2Advertisement after 10 attempts" >&2
  exit 1
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

# 3b. Self-signed TLS cert for the landing HTTPS listener (lab-grade — browsers
#     will warn on the self-signed issuer; fine for a workshop). Created ONCE and
#     reused: regenerating every run would change the Secret and needlessly roll
#     the nginx pod. SAN covers the LoadBalancer IP (= the node IP).
if ! kubectl -n landing get secret landing-tls >/dev/null 2>&1; then
  echo ">> generating self-signed landing TLS cert (SAN=IP:${LOCAL_IP})"
  cert_dir="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$cert_dir/tls.key" -out "$cert_dir/tls.crt" \
    -subj "/CN=${LOCAL_IP}" -addext "subjectAltName=IP:${LOCAL_IP}"
  kubectl -n landing create secret tls landing-tls \
    --cert="$cert_dir/tls.crt" --key="$cert_dir/tls.key"
  rm -rf "$cert_dir"
else
  echo ">> landing TLS secret already exists — reusing it"
fi

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

# 5. Print URLs from the landing LoadBalancer IP.
echo ">> waiting for landing LoadBalancer IP"
LB_IP=""
for _ in $(seq 1 30); do
  LB_IP="$(kubectl -n "${NS_LIST[2]}" get svc landing \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "$LB_IP" ]] && break
  sleep 2
done
if [[ -z "$LB_IP" ]]; then
  echo "!! landing Service has no LoadBalancer IP yet — check: kubectl -n ${NS_LIST[2]} get svc landing" >&2
  LB_IP="<pending>"
fi
cat <<EOF

>> Deployed. Access:
   Landing : http://${LB_IP}/
   Chatbot : http://${LB_IP}/chat/
   LLM API : http://${LB_IP}/llm/v1/models
EOF
