# llm-stack

llama.cpp, a Streamlit chatbot, and a landing page. One chart, one release
(`llm-stack`), deployed to a pre-existing Kubernetes cluster with plain
`helm install` — no Ansible.

Targets an Azure-style setup: CPU-only, the model baked into the llamacpp
image, images pulled from a registry (ACR by default), landing page served.

## Layout

```
aigate-helm/
  deploy.sh        idempotent wrapper: prereqs + helm upgrade --install
  values.yaml      self-contained overlay for this deployment
  llm-stack/       this chart (values.yaml here = defaults; ../values.yaml overrides)
```

## Quick start

Two knobs — your registry host and image tag. Either bake them into
`../values.yaml` (`<REGISTRY>` and `global.imageTag`) and run:

```
./deploy.sh
```

…or leave the placeholders and pass them per-build (these override the file):

```
REGISTRY=myacr.azurecr.io IMAGE_TAG=2026-07-17 ACR_NAME=myacr ./deploy.sh
```

Setting `ACR_NAME` makes `deploy.sh` create the `acr-pull` secret from ACR
admin credentials and default `REGISTRY` to the ACR login server.

## Components

Each is gated by `<component>.enabled` and lives in its own namespace. The
chart does **not** declare Namespace objects — `deploy.sh` creates them before
`helm install`, because Helm >=3.2 refuses to adopt a pre-existing,
un-annotated namespace.

| Component | Namespace | Route |
|-|-|-|
| `llamacpp` | `llamacpp` | `/llm` — llama.cpp OpenAI-compatible API |
| `chatbot` | `chatbot` | `/chat` — Streamlit chatbot UI |
| `landing` | `landing` | `/` only (anchored regex `^/$`, so it doesn't swallow other paths) |

All three Ingresses attach to `ingress.className` (top-level, shared).

Namespace names, image repos/tags, ingress paths, resources, etc. all come
from values — `llm-stack/values.yaml` is the full shape; `../values.yaml` is
the overlay this deployment actually uses.

## What deploy.sh owns (not the chart)

- **Namespace creation** — one per enabled component.
- **ingress-nginx** — installed (hostNetwork, so the node IP is the entrypoint)
  if absent; an existing controller is patched to hostNetwork +
  `--default-ssl-certificate` instead.
- **`landing-tls`** — self-signed cert in the controller's namespace, serving
  HTTPS for every path. Created once and reused; the chart does not manage it.
- **MetalLB removal** — it ARPs the same node IP the hostNetwork controller
  binds, so deploy.sh deletes it if present.
- **ACR pull secret** (`acr-pull`) — created in each namespace when `ACR_NAME`
  is set. Skip entirely for public images (also remove the `imagePullSecrets`
  lines from `../values.yaml`).
- **The images themselves** — `llamacpp` and `chatbot` must be built and pushed
  to your registry; the chart only references them.

## serverArgs

`llamacpp.serverArgs` is a flat list passed straight to `llama-server`. Edit it
in `../values.yaml` and re-run `deploy.sh` — no image rebuild needed (the model
is baked into the image, the flags are not).

## Coupled values — change together

- **Namespace + DNS.** `chatbot.config.llmEndpoint` hardcodes
  `http://llamacpp.llamacpp.svc.cluster.local:8080/v1`. Rename
  `llamacpp.namespace` and you must update that endpoint, plus `NS_LIST` and
  `--namespace` in `deploy.sh`.
- **Landing image.** `../values.yaml` pulls stock `nginx` through your registry
  (the Azure assumption — no direct Docker Hub path). If the cluster can reach
  Docker Hub, set `landing.image.repository: nginx` and drop `landing` from the
  pull-secret loop.
- **`global.imageTag`** — the fallback tag for `llamacpp`/`chatbot`. `landing`
  is pinned to `nginx:alpine` and ignores it.

## GPU / fetched model

`../values.yaml` is CPU + baked model. The chart also supports GPU
(`llamacpp.gpu.enabled: true` → `runtimeClassName: nvidia` + `nvidia.com/gpu`
limits) and fetching the model into a PVC (`llamacpp.model.source: pvc` with
`model.url`/`model.file`/`model.pvc`). The PVC binds statically to a volume you
must provision yourself — see `llm-stack/values.yaml` for the full `model`
shape.

## Inspecting changes

```
helm template llm-stack ./llm-stack -f ./values.yaml --set global.imageTag=<tag>
helm lint ./llm-stack -f ./values.yaml
helm diff upgrade llm-stack ./llm-stack -f ./values.yaml   # against a running release
```

Pass `-f ./values.yaml`: the chart's own defaults leave `image.tag` empty on
purpose, and the template `fail`s rather than guess a tag.
