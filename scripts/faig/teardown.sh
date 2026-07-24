#!/usr/bin/env bash
# Teardown for the llm-stack deploy — removes what deploy.sh installed.
#
#   ./teardown.sh          remove the app stack (llamacpp, chatbot, landing)
#   ./teardown.sh --all    ALSO remove the ingress-nginx controller (frees :80/:443)
#   ./teardown.sh -y       skip the confirmation prompt
#
# Notes:
#  - The helm release lives in the `llamacpp` namespace (deploy.sh installs it
#    there with --namespace llamacpp), even though it deploys into chatbot and
#    landing too. `helm uninstall` removes its resources across all three.
#  - Deleting the namespaces sweeps up anything created outside helm (the
#    acr-pull / landing-tls secrets, the namespaces themselves).
#  - This does NOT reinstall MetalLB; deploy.sh removed it and won't bring it back.
set -euo pipefail

RELEASE="${RELEASE:-llm-stack}"
RELEASE_NS="${RELEASE_NS:-llamacpp}"        # where deploy.sh installs the release
NS_LIST=(llamacpp chatbot landing)
INGRESS_RELEASE="${INGRESS_RELEASE:-ingress-nginx}"
INGRESS_NS="${INGRESS_NS:-ingress-nginx}"

ALL=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --all)     ALL=1 ;;
    -y|--yes)  YES=1 ;;
    -h|--help)
      echo "usage: $0 [--all] [-y]"
      echo "  --all   also uninstall ingress-nginx (frees node :80/:443)"
      echo "  -y      skip the confirmation prompt"
      exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

echo ">> will remove helm release '$RELEASE' (ns $RELEASE_NS) + namespaces: ${NS_LIST[*]}"
if [[ "$ALL" == "1" ]]; then
  echo ">> AND ingress-nginx release '$INGRESS_RELEASE' (ns $INGRESS_NS) — frees node :80/:443"
fi

if [[ "$YES" != "1" ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "aborted"; exit 1; }
fi

# helm uninstall, guarded so a missing release can't abort the run under set -e.
if helm status "$RELEASE" -n "$RELEASE_NS" >/dev/null 2>&1; then
  echo ">> helm uninstall $RELEASE -n $RELEASE_NS"
  helm uninstall "$RELEASE" -n "$RELEASE_NS"
else
  echo ">> helm release '$RELEASE' not found in $RELEASE_NS — skipping"
fi

if [[ "$ALL" == "1" ]]; then
  # Only touches OUR ingress-nginx helm release. A foreign controller that
  # deploy.sh patched in place (different namespace) is deliberately left alone.
  if helm status "$INGRESS_RELEASE" -n "$INGRESS_NS" >/dev/null 2>&1; then
    echo ">> helm uninstall $INGRESS_RELEASE -n $INGRESS_NS"
    helm uninstall "$INGRESS_RELEASE" -n "$INGRESS_NS"
  else
    echo ">> ingress release '$INGRESS_RELEASE' not found in $INGRESS_NS — skipping"
  fi
fi

# Delete namespaces last — removes leftover secrets and the (now-empty) namespaces.
DEL_NS=("${NS_LIST[@]}")
[[ "$ALL" == "1" ]] && DEL_NS+=("$INGRESS_NS")
echo ">> deleting namespaces: ${DEL_NS[*]}"
kubectl delete namespace "${DEL_NS[@]}" --ignore-not-found

echo ">> teardown complete."
