# CLAUDE.md — faig-training-workshop

> Global preferences (planning workflow, code quality, operations): `~/.claude/CLAUDE.md`
>
> On-demand docs (this repo is a **Hugo workshop repo** — `docs/` is machine-owned/deleted, so
> detail lives under root `plans/claude/`, not `docs/claude/`):
>
> | Doc | Read it when |
> |---|---|
> | [`plans/claude/reference.md`](plans/claude/reference.md) | You need the full `content/`/`scripts/`/`.github/` file map — adding a page, editing the chart, or touching a workflow file |
> | [`plans/claude/gotchas.md`](plans/claude/gotchas.md) | Before editing `.gitignore`, `repoConfig.json`, `static.yml`, `fdevsec.yaml`, `Jenkinsfile`, or anything region/licensing-sensitive in lab content |

## Project in One Line

A FortinetCloudCSE hands-on workshop — "How to Deply and Use FortiAIGate" (title typo is live,
see gotchas) — published as a Hugo static site to GitHub Pages, plus a Helm chart under
`scripts/faig/` that students deploy to a pre-existing Kubernetes cluster from Azure Cloud Shell.

## Stack Quick Reference

| Layer | Tech | Port |
|-------|------|------|
| Site generator | Hugo via `public.ecr.aws/k4n6m5h8/fortinet-hugo:latest` | 1313 (local dev) |
| Site theme/config | [CentralRepo](https://github.com/FortinetCloudCSE/CentralRepo) — mounted at build time, **not** in this repo | — |
| Local dev driver | [fortihugorunner](https://github.com/FortinetCloudCSE/fortihugorunner) CLI | — |
| Hosting | GitHub Pages (`https://fortinetcloudcse.github.io/faig-training-workshop/`) | — |
| Lab workload | Helm chart `llm-stack` (llama.cpp + Streamlit chatbot + landing page), namespaces `llamacpp`, `chatbot`, `landing` | — |

No `Dockerfile`, `hugo.toml`, `config.toml`, `docs/`, or `static/` in this repo (by design — see
gotchas). Full file map: `plans/claude/reference.md`.

## Build & Run Commands

```bash
# Preview the site locally (requires Docker + fortihugorunner on PATH)
fortihugorunner pull-image --env author-dev
fortihugorunner launch-server \
  --docker-image fortinet-hugo:latest \
  --host-port 1313 --container-port 1313 --watch-dir .
# open http://localhost:1313

# Reproduce the CI static build exactly
docker run --rm -v "$PWD:/home/UserRepo" fortinet-hugo:latest build
```

There is no test suite. Content changes are validated by rendering locally.

## Critical Rules

- **Hugo config/theme/layouts come from CentralRepo, not this repo — on purpose.** To change site
  title, banner, author, or sidebar shortcuts, edit `scripts/repoConfig.json`, not a local config file.
- **Never put anything in `docs/`.** Machine-deleted from `main` on every CentralRepo batch update. Detail: gotchas.
- **Plan/log/spec files go in root-level `plans/`, tracked** — never `docs/plans/`. Naming:
  `NNNN_YYYY-MM-DD_<git-username>_<slug>.md`. See `plans/README.md`.
- **Don't remove the leading slash from `/specs/` in `.gitignore`** — without it the pattern
  matches at any depth and swallows `scripts/faig/specs/` (Tom's chart design docs). Two plan
  locations (root `plans/` for Jeff, `scripts/faig/plans|specs/` for Tom) coexist by convention —
  don't consolidate them.
- **`scripts/repoConfig.json`'s `workshopTitle` has a live typo** ("Deply") — fix it there, not in content.
- **Lab automation is real, not just docs.** `scripts/faig/deploy.sh` is invoked directly by
  students; keep content and chart in sync when either changes.
- **`.github/workflows/static.yml` is template-managed by CentralRepo's `batch_repo_update.py`** —
  hand-edits get overwritten on the next batch run.
- **Lab commands are region/licensing-sensitive** — verify against the current lab environment before changing.
- **`codex-advisory-review.yml` uses `pull_request_target` deliberately** — do not convert to `pull_request`.
- **`Jenkinsfile`'s content-check stage is disabled** (`when { expression { false } }`) — it does not lint content.
- **`migration_log*.csv` are stale, not about this repo** — never treat as inputs.
- Shortcodes come from the CentralRepo theme (`{{% notice %}}`, `{{< notice >}}`, `{{< relref >}}`);
  repo-local overrides live in `layouts/shortcodes/` — grep existing content before inventing a new one.
- Page ordering is `weight` in front matter, not filename.
- Deploy triggers on push to `main` (+ manual `workflow_dispatch`) — branch pushes do not deploy.
- `fdevsec.yaml` is half-configured (`id.app` still a placeholder) — leave it unless asked.

Full detail, incident history, and exact values for all of the above: `plans/claude/gotchas.md`.

## Environment Variables

None required for authoring. CI-only secrets: `LW_ACCOUNT_NAME`, `LW_API_KEY`, `LW_API_SECRET`
(Lacework), `OPENAI_API_KEY` (advisory review), `GITHUB_TOKEN` (Pages).

`scripts/faig/deploy.sh` optional overrides: `CHART_DIR`, `VALUES`, `RELEASE`, `REGISTRY`,
`IMAGE_TAG`, `ACR_NAME`, `REPULL` (default 1 — forces re-pull/restart of `llamacpp` and `chatbot`).

Optional locally: `DOCKER_CONTEXT` / `DOCKER_HOST` — fortihugorunner honors the active Docker context.

## Common Tasks

**Add a workshop section**: create the page bundle under the right `content/NN_*/` parent with
`title`, `linkTitle`, `weight` front matter; preview with `launch-server`.

**Change site chrome** (title, banner, sidebar links): edit `scripts/repoConfig.json`.

**Plan/log/spec files**: write them to root-level `plans/` as
`NNNN_YYYY-MM-DD_<git-username>_<slug>.md` (+ optional `.log.md`, `.spec.md`) and **commit them** —
root `plans/` is tracked here, same as the other five Hugo repos. Never `docs/plans/`. `NNNN` is a
per-repo sequence; the log is optional; on completion, durable facts get promoted into this file
and the plan is left to decay. See `plans/README.md`.

**Change the lab workload**: edit `scripts/faig/llm-stack/` + `scripts/faig/values.yaml`, then
update the content pages that walk students through `deploy.sh` output.

**Debug a broken published page**: run the CI build command locally — the dev server is more
forgiving than the static build. `errorLevel` in `scripts/repoConfig.json` is `warning`, so Hugo
warnings do not fail the build.
