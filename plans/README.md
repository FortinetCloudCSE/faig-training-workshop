# plans/

Plan, spec, and log files for work done in this repo. See `CLAUDE.md` for the workflow.

**Why not `docs/plans/`:** `docs/` is build output here. `.gitignore` excludes it, and the template upgrade tool `CentralRepo/scripts/batch_repo_update.py` hardcodes `FOLDERS_TO_DELETE = ["docs"]` with `BRANCH = "main"` — it deletes every blob under `docs/` via the GitHub tree API and pushes that deletion straight to `main`. Anything filed under `docs/` is either invisible to git or destroyed by the next template upgrade. (The tool does not read `repo_upgrade_spec.json`; that file documents the same list but is not what executes, so the two can drift.)

A root-level `plans/` is inert to Hugo — Hugo reads only `content/`, `layouts/`, `static/`, `assets/`, `data/`, `i18n/`, `archetypes/`, `themes/` — and is outside the tool's delete list.

**Naming:** `YYYY-MM-DD_<git-username>_<slug>.md`, with a matching `.log.md` and an optional `.spec.md`.
