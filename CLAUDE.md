# CLAUDE.md — faig-training-workshop

> Global preferences (planning workflow, code quality, operations): `~/.claude/CLAUDE.md`

## Project in One Line

A FortinetCloudCSE hands-on workshop — "How to Deply and Use FortiAIGate" (title typo is live, see gotchas) — published as a Hugo static site to GitHub Pages, plus a Helm chart under `scripts/faig/` that students deploy to a pre-existing Kubernetes cluster from Azure Cloud Shell.

## Stack Quick Reference

| Layer | Tech | Port |
|-------|------|------|
| Site generator | Hugo via `public.ecr.aws/k4n6m5h8/fortinet-hugo:latest` | 1313 (local dev) |
| Site theme/config | [CentralRepo](https://github.com/FortinetCloudCSE/CentralRepo) — mounted at build time, **not** in this repo | — |
| Local dev driver | [fortihugorunner](https://github.com/FortinetCloudCSE/fortihugorunner) CLI | — |
| Hosting | GitHub Pages (`https://fortinetcloudcse.github.io/faig-training-workshop/`) | — |
| Lab workload | Helm chart `llm-stack` (llama.cpp + Streamlit chatbot + landing page), namespaces `llamacpp`, `chatbot`, `landing` | — |

## Key File Map

```
content/                       — workshop pages (Hugo page bundles, ordered by `weight`)
  _index.md
  secure-ai-at-runtime-fortiaigate.png
  01_Environment_Setup/        — _index.md, 01_setting_up_the_llm.md + screenshots
  02_FortiAIGate_Setup/        — _index.md + screenshots (no numbered pages)
  03_FortiAIGate_Config/       — _index.md, 01_configure_ai_chatbot.md + screenshots
  04_Demo_FortiAIGate/         — _index.md, 01–07_use_case_*.md + screenshots
layouts/shortcodes/            — repo-local shortcodes: ContainerFlow.html, FTNThugoFlow.html, fortihugorunner.html
scripts/repoConfig.json        — per-repo site config (title, author, banner, shortcuts)
scripts/faig/                  — lab automation students actually run
  deploy.sh, teardown.sh       — helm upgrade --install wrapper / cleanup
  values.yaml                  — self-contained values overlay
  llm-stack/                   — Helm chart (chatbot, llamacpp, landing subtrees)
  plans/, specs/               — historical design docs for the chart (tracked)
plans/                         — plan/log/spec files for this repo (see gotchas); plans/README.md explains why
Jenkinsfile                    — GitHub commit-status pipeline; its content-check stage is disabled
fdevsec.yaml                   — FortiDevSec scan config
.github/workflows/
  static.yml                     — build + deploy to Pages; `push` to `main` + `workflow_dispatch`
                                   (inputs: `runner_type`, `image_variant` prod/dev)
  lacework-code-security-pr.yml  — `on: pull_request`
  codex-advisory-review.yml      — `on: pull_request_target` (opened, synchronize, reopened, ready_for_review)
repo_upgrade_spec.json / .repo_upgrade_version  — both say `Hugo-v2.1`
migration_log.csv, migration_log_dry_run.csv    — historical image-migration artifacts
```

No `Dockerfile`, `hugo.toml`, `config.toml`, `docs/`, or `static/` in this repo.

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

## Critical Patterns & Gotchas

- **No `hugo.toml` or `config.toml` here — on purpose.** Hugo config, theme, and layouts come from CentralRepo, which the container mounts alongside this repo. To change the site title, banner text, author, or sidebar shortcuts, edit **`scripts/repoConfig.json`**.
- **`docs/` is doubly machine-owned — never put anything there.** `.gitignore` excludes `docs/`, and `CentralRepo/scripts/batch_repo_update.py` hardcodes `FOLDERS_TO_DELETE = ["docs"]` with `BRANCH = "main"`, deleting every blob under `docs/` via the GitHub tree API and pushing that deletion straight to `main`. Nuance: that script does **not** read `repo_upgrade_spec.json` — the spec file documents the same lists but is not what executes, so the two can silently drift.
- **Plan/log/spec files go in root-level `plans/`, not `docs/plans/`.** `plans/` is inert to Hugo (Hugo only reads `content/`, `layouts/`, `static/`, `assets/`, `data/`, `i18n/`, `archetypes/`, `themes/`) and is outside `FOLDERS_TO_DELETE`. `plans/README.md` in this repo states the convention.
- **`.gitignore` previously listed `plans/` and `specs/`; those two lines were just removed** so the new convention can be tracked. If a teammate re-adds them, treat it as a deliberate opt-out worth a conversation, not a silent revert.
  - Side effect of the old ignore: `scripts/faig/plans/` and `scripts/faig/specs/` are tracked anyway (they predate the ignore lines). Likewise `package.json` / `package-lock.json` are listed in `.gitignore` but tracked.
- **The `workshopTitle` in `scripts/repoConfig.json` has a typo:** `"How to Deply and Use FortiAIGate"`. It renders on the published site. Fix it there, not in content. Other live values: `author` `"Tom Walsh"`, `errorLevel` `"warning"`, `marketingCode` `"FortiHugo202"`, `themeVariant` `"CloudCSEMovie"`.
- **This repo *does* carry lab automation.** `scripts/faig/deploy.sh` is invoked directly by students — `content/01_Environment_Setup/01_setting_up_the_llm.md` tells them to `cd $HOME/faig-training-workshop/scripts/faig/ && ./deploy.sh`. Content and chart must stay in sync: the script provisions an in-cluster NFS server + default StorageClass, validates an RWX test volume, and runs `helm upgrade --install` for the `llm-stack` release.
- **`.github/workflows/static.yml` is template-managed.** `batch_repo_update.py` overwrites it from the operator's CentralRepo checkout (`FILES_TO_COPY`) — hand-edits get lost. It also copies in a `Dockerfile` (this repo currently has none) and deletes `layouts/shortcodes/FTNThugoFlow.html`, `docker-compose.yml`, `hugo.toml`, `config.toml`, and the `scripts/docker_*.sh` set. `FTNThugoFlow.html` is present here and unused by content — expect it to disappear on the next batch run.
- **Region-sensitive lab commands.** The most recent commit (`132d20b`) updated `cloudapp` commands for an alternate region, and `5d132d4` reworked the license copy process — lab steps embed region and licensing assumptions. Verify against the current lab environment before changing them.
- **Container mount layout:** the workshop repo mounts at `/home/UserRepo`; CentralRepo lives at `/home/CentralRepo`; Hugo output lands in `/home/CentralRepo/public` (CI copies that to `docs/` and uploads it as the Pages artifact).
- **Shortcodes come from the CentralRepo theme.** Content here uses `{{% notice %}}` (25x), `{{< notice >}}` (11x), and `{{< relref >}}`. Repo-local overrides live in `layouts/shortcodes/`. Grep existing content before inventing a new shortcode.
- **Page ordering is `weight` in front matter,** not filename. The numeric prefixes are cosmetic.
- **Deploy triggers on push to `main`** (plus manual `workflow_dispatch`). Branch pushes do not deploy.
- **`fdevsec.yaml` is half-configured:** `id.org` is a real UUID (`2e3b7756-…`), but `id.app` is still the literal placeholder `<insert app id here>`. Scanners enabled: `sast`, `secret`, `sca`, `iac`, `container`; `resource.serial_scan: false`; `fail_pipeline.risk_rating: 7`. Leave it unless asked.
- **`codex-advisory-review.yml` uses `pull_request_target` deliberately** so `OPENAI_API_KEY` comes from the trusted base branch and the PR head is never checked out. Do not convert it to `pull_request`.
- **`Jenkinsfile` does not lint content.** Its "Checking for question/discussion section" stage is gated by `when { expression { false } }`; what actually runs is `deleteDir()` plus a GitHub commit-status update.
- **`migration_log*.csv` are stale artifacts and not even about this repo** — their paths point at `/home/ubuntu/pythonProjects/UserRepo/content/…`. Never treat them as inputs.

## Environment Variables

None required for authoring. CI-only secrets: `LW_ACCOUNT_NAME`, `LW_API_KEY`, `LW_API_SECRET` (Lacework), `OPENAI_API_KEY` (advisory review), `GITHUB_TOKEN` (Pages).

`scripts/faig/deploy.sh` optional overrides: `CHART_DIR`, `VALUES`, `RELEASE`, `REGISTRY`, `IMAGE_TAG`, `ACR_NAME`, `REPULL` (default 1 — forces re-pull/restart of `llamacpp` and `chatbot`).

Optional locally: `DOCKER_CONTEXT` / `DOCKER_HOST` — fortihugorunner honors the active Docker context.

## Common Tasks

**Add a workshop section**: create the page bundle under the right `content/NN_*/` parent with `title`, `linkTitle`, `weight` front matter; preview with `launch-server`.

**Change site chrome** (title, banner, sidebar links): edit `scripts/repoConfig.json`.

**Plan/log/spec files**: write them to root-level `plans/` as `YYYY-MM-DD_<git-username>_<slug>.md` (+ `.log.md`, optional `.spec.md`). Never `docs/plans/`.

**Change the lab workload**: edit `scripts/faig/llm-stack/` + `scripts/faig/values.yaml`, then update the content pages that walk students through `deploy.sh` output.

**Debug a broken published page**: run the CI build command locally — the dev server is more forgiving than the static build. `errorLevel` in `scripts/repoConfig.json` is `warning`, so Hugo warnings do not fail the build.
