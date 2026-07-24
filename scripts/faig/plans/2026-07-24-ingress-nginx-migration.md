# Ingress-nginx Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MetalLB with the nginx ingress controller in `deploy.sh`, moving path routing (`/`, `/chat`, `/llm`) out of the landing pod and into Ingress resources, so FortiAIGate can later attach its own Ingress for `/ui`, `/v1/...`, and the `/` catch-all.

**Architecture:** ingress-nginx runs with `hostNetwork` (binds the node's `:80`/`:443`, no LoadBalancer/MetalLB). Three Ingress resources — `/` (Exact) → landing, `/chat` (Prefix) → chatbot, `/llm` (regex, prefix stripped) → llamacpp — replace the landing pod's reverse-proxy config. The landing pod becomes a plain HTTP static server (`ClusterIP`). `deploy.sh` gains a MetalLB teardown step and an ingress-nginx reconcile-and-repair step (install / helm-upgrade / patch-foreign). TLS terminates at the controller via `--default-ssl-certificate` pointing at the existing self-signed cert.

**Tech Stack:** Bash, kubectl, Helm 3, the `llm-stack` Helm chart, the `ingress-nginx/ingress-nginx` Helm chart.

## Global Constraints

- Spec: `scripts/faig/specs/2026-07-24-ingress-nginx-migration-design.md`.
- **No unit-test framework exists** for this infra work. Each task's "test" is a deterministic verification command: `bash -n deploy.sh` (syntax), `helm template`/`helm lint` (chart render), and `grep` assertions on rendered output. Treat a failing grep/render exactly like a failing unit test — fix before moving on.
- `deploy.sh` runs under `set -euo pipefail`. Every new kubectl deletion uses `--ignore-not-found`; every conditional block is guarded so a rerun is a clean no-op.
- Exact service targets (do not change — selectors are immutable):
  - landing: Service `landing`, port `{{ .Values.landing.service.port }}` (80), ns `landing`.
  - chatbot: Service `{{ .Values.chatbot.name }}` (`chatbot`), port `{{ .Values.chatbot.service.port }}` (8501), ns `chatbot`.
  - llamacpp: Service `llamacpp`, port `{{ .Values.llamacpp.service.port }}` (8080), ns `llamacpp`.
- IngressClass name is `nginx`. Ingress resources carry **no `host`** (raw-IP access must match).
- MetalLB version this script installed and must tear down: `v0.14.3`.
- Helm binary: v3.16.3. kubectl: v1.36.

---

### Task 1: Landing pod becomes a static-only HTTP server

Strip the reverse-proxy and TLS responsibilities from the landing pod — routing moves to Ingress (Task 2), TLS moves to the controller (Task 4). The pod ends up as stock nginx serving `/` on `:80` only.

**Files:**
- Modify: `scripts/faig/llm-stack/templates/landing/nginx-config.yaml`
- Modify: `scripts/faig/llm-stack/templates/landing/service.yaml`
- Modify: `scripts/faig/llm-stack/templates/landing/deployment.yaml`
- Modify: `scripts/faig/values.yaml` (landing section, lines ~123–141)

**Interfaces:**
- Consumes: nothing.
- Produces: a `landing` Service of `type: ClusterIP` exposing only port `80`; a landing pod with no `443` port, no TLS volume/mount; an nginx config that only serves static `/`. Task 2's landing Ingress targets this Service's port `80`.

- [ ] **Step 1: Render the current landing manifests to capture the baseline**

Run:
```bash
cd scripts/faig
helm template llm-stack ./llm-stack -f values.yaml --show-only templates/landing/service.yaml --show-only templates/landing/nginx-config.yaml
```
Expected (baseline, pre-change): Service shows `type: LoadBalancer` and a `443` port; the ConfigMap contains `proxy_pass` blocks and `listen 443 ssl`.

- [ ] **Step 2: Rewrite `nginx-config.yaml` to static-only**

Replace the entire file with:
```yaml
{{- if .Values.landing.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: landing-nginx
  namespace: {{ .Values.landing.namespace }}
  labels:
    {{- include "llm-stack.labels" . | nindent 4 }}
data:
  default.conf: |
    server {
      listen 80;
      server_name _;

      # Static landing page only. All path routing (/chat, /llm, /ui, catch-all)
      # is handled by the nginx ingress controller, not this pod.
      location / {
        root /usr/share/nginx/html;
        index index.html;
      }
    }
{{- end }}
```

- [ ] **Step 3: Remove the 443 port from `service.yaml`**

Replace the `spec` block so only the HTTP port and `ClusterIP` remain. The full file becomes:
```yaml
{{- if .Values.landing.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: landing
  namespace: {{ .Values.landing.namespace }}
  labels:
    {{- include "llm-stack.labels" . | nindent 4 }}
spec:
  type: {{ .Values.landing.service.type | default "ClusterIP" }}
  selector:
    app: landing
  ports:
    - name: http
      port: {{ .Values.landing.service.port }}
      targetPort: 80
{{- end }}
```

- [ ] **Step 4: Remove the 443 port, TLS volume, and TLS mount from `deployment.yaml`**

In `scripts/faig/llm-stack/templates/landing/deployment.yaml`:
- Delete the `{{- if $l.tls.enabled }} - containerPort: 443 {{- end }}` block under `ports`.
- Delete the `{{- if $l.tls.enabled }} - name: tls ... readOnly: true {{- end }}` volumeMount block.
- Delete the `{{- if $l.tls.enabled }} - name: tls secret: ... {{- end }}` volume block.

Resulting `ports`, `volumeMounts`, and `volumes` sections:
```yaml
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: html
          configMap:
            name: landing-html
        - name: nginx-conf
          configMap:
            name: landing-nginx
```
Leave the `checksum/nginx` annotation and the rest of the pod spec intact.

- [ ] **Step 5: Update the landing section of `values.yaml`**

Set the service to ClusterIP and remove the pod-level TLS block. Replace the landing section (currently lines ~123–141) with:
```yaml
landing:
  enabled: true
  namespace: landing
  image:
    # Stock nginx. If the cluster can reach Docker Hub directly, change this to
    # `nginx` and drop landing from the pull-secret loop in deploy.sh.
    repository: nginx
    tag: alpine                # stock nginx tag, not global.imageTag
    pullPolicy: IfNotPresent
  service:
    port: 80
    type: ClusterIP            # was LoadBalancer (MetalLB). Ingress fronts it now.
  # Path routing and TLS termination now live on the nginx ingress controller
  # (see deploy.sh + templates/*/ingress.yaml), not on this pod.
  ingress:
    className: nginx
```

- [ ] **Step 6: Re-render and verify the landing pod is static-only**

Run:
```bash
cd scripts/faig
helm template llm-stack ./llm-stack -f values.yaml \
  --show-only templates/landing/service.yaml \
  --show-only templates/landing/nginx-config.yaml \
  --show-only templates/landing/deployment.yaml
```
Expected:
- Service: `type: ClusterIP`, exactly one port (`80`), no `443`.
- ConfigMap: no `proxy_pass`, no `listen 443`, no `ssl_certificate`.
- Deployment: no `containerPort: 443`, no `name: tls` volume or mount.

Assert programmatically:
```bash
helm template llm-stack ./llm-stack -f values.yaml | grep -E 'proxy_pass|listen 443|containerPort: 443|landing-tls' && echo "FAIL: TLS/proxy remnants in landing" || echo "PASS: landing is static-only"
```
Expected: `PASS: landing is static-only`.

- [ ] **Step 7: Commit**

```bash
cd scripts/faig
git add llm-stack/templates/landing/nginx-config.yaml llm-stack/templates/landing/service.yaml llm-stack/templates/landing/deployment.yaml values.yaml
git commit -m "landing: static-only pod (ClusterIP, no TLS/proxy); routing moves to ingress"
```

---

### Task 2: Add Ingress resources for /, /chat, /llm

Three separate Ingress resources (one per component namespace, co-located with each Service). They must be separate because `rewrite-target`/`use-regex` are per-Ingress annotations that apply to every path in the resource — `/llm` needs a strip, `/chat` must not have one.

**Files:**
- Create: `scripts/faig/llm-stack/templates/landing/ingress.yaml`
- Create: `scripts/faig/llm-stack/templates/chatbot/ingress.yaml`
- Create: `scripts/faig/llm-stack/templates/llamacpp/ingress.yaml`

**Interfaces:**
- Consumes: the `landing` (port 80), `chatbot` (port 8501), `llamacpp` (port 8080) Services, and `.Values.landing.ingress.className` (`nginx`) from Task 1.
- Produces: three Ingress objects on IngressClass `nginx`, no `host`. Precedence: `/` Exact (landing) > FortiAIGate's future `/` Prefix; `/chat` and `/llm` prefixes > that catch-all. FortiAIGate attaches its own Ingress later — not created here.

- [ ] **Step 1: Create the landing Ingress (`/` Exact)**

`scripts/faig/llm-stack/templates/landing/ingress.yaml`:
```yaml
{{- if .Values.landing.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: landing
  namespace: {{ .Values.landing.namespace }}
  labels:
    {{- include "llm-stack.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.landing.ingress.className }}
  rules:
    - http:
        paths:
          # Exact so this owns ONLY the bare root; FortiAIGate's future
          # `/` Prefix catch-all takes everything else.
          - path: /
            pathType: Exact
            backend:
              service:
                name: landing
                port:
                  number: {{ .Values.landing.service.port }}
{{- end }}
```

- [ ] **Step 2: Create the chatbot Ingress (`/chat` Prefix, prefix preserved)**

`scripts/faig/llm-stack/templates/chatbot/ingress.yaml`:
```yaml
{{- if .Values.chatbot.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chatbot
  namespace: {{ .Values.chatbot.namespace }}
  labels:
    {{- include "llm-stack.labels" . | nindent 4 }}
  annotations:
    # Streamlit websockets + long-lived streams. ingress-nginx upgrades
    # websockets automatically; just raise the read timeout.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  ingressClassName: {{ .Values.landing.ingress.className }}
  rules:
    - http:
        paths:
          # Prefix PRESERVED — Streamlit runs with baseUrlPath={{ .Values.chatbot.path }}.
          - path: {{ .Values.chatbot.path }}
            pathType: Prefix
            backend:
              service:
                name: {{ .Values.chatbot.name }}
                port:
                  number: {{ .Values.chatbot.service.port }}
{{- end }}
```

- [ ] **Step 3: Create the llamacpp Ingress (`/llm` regex, prefix stripped)**

`scripts/faig/llm-stack/templates/llamacpp/ingress.yaml`:
```yaml
{{- if .Values.llamacpp.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: llamacpp
  namespace: {{ .Values.llamacpp.namespace }}
  labels:
    {{- include "llm-stack.labels" . | nindent 4 }}
  annotations:
    # Strip the {{ .Values.llamacpp.path }} prefix — llama-server expects /v1/...
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    # No body cap (matches the old client_max_body_size 0) and long timeouts.
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  ingressClassName: {{ .Values.landing.ingress.className }}
  rules:
    - http:
        paths:
          - path: {{ .Values.llamacpp.path }}(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: llamacpp
                port:
                  number: {{ .Values.llamacpp.service.port }}
{{- end }}
```

- [ ] **Step 4: Render and verify all three Ingresses**

Run:
```bash
cd scripts/faig
helm template llm-stack ./llm-stack -f values.yaml \
  --show-only templates/landing/ingress.yaml \
  --show-only templates/chatbot/ingress.yaml \
  --show-only templates/llamacpp/ingress.yaml
```
Expected: three `kind: Ingress` docs, all `ingressClassName: nginx`, none with a `host:` line.

Assert programmatically:
```bash
OUT=$(helm template llm-stack ./llm-stack -f values.yaml)
echo "$OUT" | grep -q 'pathType: Exact' && echo "PASS exact" || echo "FAIL exact"
echo "$OUT" | grep -q 'path: /chat' && echo "PASS chat" || echo "FAIL chat"
echo "$OUT" | grep -q 'path: /llm(/|$)(.*)' && echo "PASS llm-regex" || echo "FAIL llm-regex"
echo "$OUT" | grep -q 'rewrite-target: /$2' && echo "PASS rewrite" || echo "FAIL rewrite"
echo "$OUT" | grep -c 'ingressClassName: nginx'   # expect 3
echo "$OUT" | grep -c 'kind: Ingress'             # expect 3
```
Expected: `PASS` on all four, and both counts print `3`.

- [ ] **Step 5: Lint the chart**

Run:
```bash
cd scripts/faig
helm lint ./llm-stack -f values.yaml
```
Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 6: Commit**

```bash
cd scripts/faig
git add llm-stack/templates/landing/ingress.yaml llm-stack/templates/chatbot/ingress.yaml llm-stack/templates/llamacpp/ingress.yaml
git commit -m "ingress: add / (Exact), /chat, /llm (strip) Ingress resources on nginx class"
```

---

### Task 3: Replace the MetalLB install block with a MetalLB teardown

Delete MetalLB when detected so it can't fight ingress-nginx over the node IP. This removes the current install/pool logic (lines ~34–88) and adds an idempotent teardown.

**Files:**
- Modify: `scripts/faig/deploy.sh` (remove lines ~34–88; insert teardown after the `apply()` helper at line ~32)

**Interfaces:**
- Consumes: nothing (runs first).
- Produces: a cluster with no MetalLB. `LOCAL_IP` (node IP) determination is **kept** — later tasks reuse it for the TLS SAN and final URLs.

- [ ] **Step 1: Delete the MetalLB install + pool block**

Remove the entire block from the comment `# 1. MetalLB — ...` (line ~34) through the end of the `if [[ -z "$pool_applied" ]]; ... fi` block (line ~88), inclusive. Keep the `apply()` helper (line ~32) and the namespaces block (`# 2. Namespaces`, line ~90) — they stay.

- [ ] **Step 2: Insert the MetalLB teardown and keep LOCAL_IP**

Immediately after the `apply() { kubectl apply -f - ; }` line, insert:
```bash
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
  # IPAddressPool/L2Advertisement CRs, RBAC, webhooks).
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
```

- [ ] **Step 3: Verify script syntax**

Run:
```bash
cd scripts/faig
bash -n deploy.sh && echo "PASS syntax"
```
Expected: `PASS syntax`.

- [ ] **Step 4: Verify MetalLB install is gone and teardown is present**

Run:
```bash
cd scripts/faig
grep -q 'metallb-native.yaml' deploy.sh && grep -q 'kubectl delete -f https' deploy.sh && ! grep -q 'IPAddressPool' deploy.sh && echo "PASS teardown-only"
```
Expected: `PASS teardown-only` (the manifest URL is referenced only by the `delete`; no `IPAddressPool`/`L2Advertisement` creation remains).

- [ ] **Step 5: Commit**

```bash
cd scripts/faig
git add deploy.sh
git commit -m "deploy: tear down MetalLB when detected (replaces install block)"
```

---

### Task 4: TLS secret relocation + ingress-nginx reconcile-and-repair

Ensure the self-signed cert lives where the controller expects it, then guarantee a correctly-exposed nginx controller: install ours, upgrade ours, or patch a foreign one in place.

**Files:**
- Modify: `scripts/faig/deploy.sh` (replace the landing-ns TLS secret block ~114–129; add the reconcile step before the `helm upgrade` at ~140)

**Interfaces:**
- Consumes: `LOCAL_IP` from Task 3.
- Produces: an nginx ingress controller bound to the node's `:80`/`:443` with `--default-ssl-certificate=<ctrl-ns>/landing-tls`, and a `landing-tls` secret in that controller's namespace. Task 5's health gate depends on the controller answering on `:80`.

- [ ] **Step 1: Replace the TLS secret block with a namespace-parameterized helper**

Replace the existing `# 3b. Self-signed TLS cert ...` block (lines ~114–129) with a function that creates the cert in a given namespace, generate-once:
```bash
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
```

- [ ] **Step 2: Add the ingress-nginx reconcile function**

Insert after `ensure_landing_tls` (still before the `# 2. Namespaces` workload steps is fine; it only needs `LOCAL_IP`). Add:
```bash
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
    local cidx
    cidx="$(kubectl -n "$ns" get "$kind" "$name" \
      -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' \
      | grep -nx controller | cut -d: -f1)"
    cidx=$((cidx - 1))
    kubectl -n "$ns" patch "$kind" "$name" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/${cidx}/args/-\",\"value\":\"--default-ssl-certificate=${ns}/landing-tls\"}]"
  fi
  kubectl -n "$ns" rollout status "$kind/$name" --timeout=180s
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
```

- [ ] **Step 3: Verify script syntax**

Run:
```bash
cd scripts/faig
bash -n deploy.sh && echo "PASS syntax"
```
Expected: `PASS syntax`.

- [ ] **Step 4: Verify the three reconcile branches and flags are present**

Run:
```bash
cd scripts/faig
grep -q 'helm status ingress-nginx' deploy.sh && \
grep -q 'patch_ingress_foreign' deploy.sh && \
grep -q 'controller.hostNetwork=true' deploy.sh && \
grep -q 'default-ssl-certificate=ingress-nginx/landing-tls' deploy.sh && \
echo "PASS reconcile-branches"
```
Expected: `PASS reconcile-branches`.

- [ ] **Step 5: Commit**

```bash
cd scripts/faig
git add deploy.sh
git commit -m "deploy: ingress-nginx reconcile (install/upgrade/patch-foreign) + TLS in controller ns"
```

---

### Task 5: Wire the flow, add the health gate, and fix the final URLs

Call the reconcile in the right order, replace the LoadBalancer-IP wait with the node IP, and add the health gate that fails loudly if the controller isn't actually answering.

**Files:**
- Modify: `scripts/faig/deploy.sh` (invoke `reconcile_ingress_nginx` before the workload; replace the final URL block ~167–186)

**Interfaces:**
- Consumes: `reconcile_ingress_nginx`, `LOCAL_IP` (Tasks 3–4).
- Produces: the finished script. No further tasks depend on it.

- [ ] **Step 1: Invoke the reconcile before the workload install**

Immediately before the `# 4. Install / upgrade.` / `helm upgrade --install "$RELEASE"` step, add:
```bash
# Ensure a correctly-exposed nginx ingress controller exists before the workload
# (its Ingress resources need a controller to bind to).
reconcile_ingress_nginx
```

- [ ] **Step 2: Replace the final URL block with a health gate + node-IP URLs**

Replace the `# 5. Print URLs from the landing LoadBalancer IP.` block through the end of the file (lines ~167–186) with:
```bash
# 5. Health gate: with hostNetwork the node IP IS the entrypoint — prove the
#    controller is actually bound to :80 before declaring success. Any HTTP
#    status (even 404) proves the bind; a connection refusal does not.
echo ">> health check: http://${LOCAL_IP}/"
gate_ok=""
for _ in $(seq 1 30); do
  if curl -sk -o /dev/null -w '%{http_code}' "http://${LOCAL_IP}/" 2>/dev/null | grep -Eq '^[1-5][0-9][0-9]$'; then
    gate_ok="1"; break
  fi
  sleep 2
done
if [[ -z "$gate_ok" ]]; then
  echo "!! ingress controller is not answering on http://${LOCAL_IP}/ — the lab will not work." >&2
  echo "!! diagnose: kubectl get pods -A -l app.kubernetes.io/component=controller -o wide" >&2
  echo "!!           kubectl -n ingress-nginx describe pod -l app.kubernetes.io/component=controller" >&2
  exit 1
fi

cat <<EOF

>> Deployed. Access (self-signed TLS — browsers will warn):
   Landing : https://${LOCAL_IP}/
   Chatbot : https://${LOCAL_IP}/chat/
   LLM API : https://${LOCAL_IP}/llm/v1/models

   FortiAIGate (installed separately) attaches its own Ingress for /ui, /v1/...,
   and the '/' catch-all against IngressClass nginx.
EOF
```

- [ ] **Step 3: Verify final script syntax**

Run:
```bash
cd scripts/faig
bash -n deploy.sh && echo "PASS syntax"
```
Expected: `PASS syntax`.

- [ ] **Step 4: Verify flow ordering (teardown → reconcile → helm workload → gate)**

Run:
```bash
cd scripts/faig
awk '
  /metallb detected/                 {print NR": teardown"}
  /reconcile_ingress_nginx$/         {print NR": reconcile-call"}
  /helm upgrade --install "\$RELEASE"/ {print NR": workload"}
  /health check: http/               {print NR": gate"}
' deploy.sh
```
Expected: line numbers strictly increasing in the order `teardown` < `reconcile-call` < `workload` < `gate`.

- [ ] **Step 5: Full chart render + lint regression**

Run:
```bash
cd scripts/faig
helm lint ./llm-stack -f values.yaml
helm template llm-stack ./llm-stack -f values.yaml >/dev/null && echo "PASS full-render"
```
Expected: `0 chart(s) failed` and `PASS full-render`.

- [ ] **Step 6: Commit**

```bash
cd scripts/faig
git add deploy.sh
git commit -m "deploy: wire reconcile into flow, add :80 health gate, node-IP URLs"
```

---

## Self-Review Notes

- **Spec coverage:** MetalLB teardown (Task 3), ingress-nginx install/upgrade/patch-foreign reconcile (Task 4), hostNetwork exposure (Task 4), TLS at controller via default cert (Task 4), landing static-only + ClusterIP (Task 1), three Ingress routes with correct strip/preserve semantics (Task 2), health gate + node-IP URLs (Task 5), FortiAIGate-owns-its-Ingress (documented, nothing to build — Task 2/5 notes). All spec sections map to a task.
- **Placeholder scan:** none — every step has concrete code and a concrete verification command.
- **Type/name consistency:** `landing-tls` secret name, `ensure_landing_tls`, `install_ingress_ours`, `patch_ingress_foreign`, `reconcile_ingress_nginx`, and `LOCAL_IP` are used identically across Tasks 3–5. Service names/ports match the chart (`landing`/80, `chatbot`/8501, `llamacpp`/8080). IngressClass `nginx` and `.Values.landing.ingress.className` consistent across Task 1 and 2.
