# faig-training-workshop — Key File Map & Reference

> Detail split out of `CLAUDE.md` by context-hygiene. See `CLAUDE.md` for the always-loaded rules.

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
  plans/, specs/               — Tom's design docs for the chart (tracked)
plans/                         — Jeff's plan/log/spec files, `NNNN_` prefixed (tracked); see gotchas re: /specs/
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
