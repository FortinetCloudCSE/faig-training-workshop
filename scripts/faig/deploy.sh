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

# 1. ingress-nginx — install only if no nginx ingressclass exists.
if kubectl get ingressclass nginx >/dev/null 2>&1; then
  echo ">> ingress-nginx present — reusing it"
else
  echo ">> installing ingress-nginx"
  helm upgrade --install ingress-nginx ingress-nginx \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace --wait
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

# 5. Print URLs.
NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
cat <<EOF

>> Deployed. Access (self-signed cert — expect a browser warning):
   Landing : https://${NODE_IP}/
   Chatbot : https://${NODE_IP}/chat/
   LLM API : https://${NODE_IP}/llm/v1/models
   (Substitute the public IP / DNS that fronts your nodes for ${NODE_IP}.)
EOF
