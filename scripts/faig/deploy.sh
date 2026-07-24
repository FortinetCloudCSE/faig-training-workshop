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
  kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml --ignore-not-found
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
