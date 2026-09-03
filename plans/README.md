# plans/

Plan, spec, and log files for work done in this repo. See `CLAUDE.md` for the workflow.

**Why not `docs/plans/`:** `docs/` is build output here. `.gitignore` excludes it, and the template upgrade tool `CentralRepo/scripts/batch_repo_update.py` hardcodes `FOLDERS_TO_DELETE = ["docs"]` with `BRANCH = "main"` — it deletes every blob under `docs/` via the GitHub tree API and pushes that deletion straight to `main`. Anything filed under `docs/` is either invisible to git or destroyed by the next template upgrade. (The tool does not read `repo_upgrade_spec.json`; that file documents the same list but is not what executes, so the two can drift.)

A root-level `plans/` is inert to Hugo — Hugo reads only `content/`, `layouts/`, `static/`, `assets/`, `data/`, `i18n/`, `archetypes/`, `themes/` — and is outside the tool's delete list.

## Naming

```
NNNN_YYYY-MM-DD_<git-username>_<slug>.md        # plan
NNNN_YYYY-MM-DD_<git-username>_<slug>.log.md    # log, optional
NNNN_YYYY-MM-DD_<git-username>_<slug>.spec.md   # spec, optional
```

`NNNN` is a per-repo sequence, zero-padded. Next number:

```bash
printf '%04d\n' $(( $(ls plans | grep -oE '^[0-9]{4}' | sort -n | tail -1 | sed 's/^0*//;s/^$/0/') + 1 ))
```

Never number forward-only in a directory that already holds unnumbered files — ASCII sorts `0` before `2`, so a new `0007_2026-…` would sort *above* an older `2026-06-…` and `ls` would show reverse chronology. Retrofit the whole directory or leave it all alone.

## Lifecycle

Every plan carries a `Status:` header: `Proposed` → `Approved` → `Complete`, plus `Superseded` and `Abandoned` as terminal states. `Superseded` requires a `Superseded-By: NNNN` pointer, and the replacing plan carries `Supersedes: NNNN`.

**Once a plan is `Approved`, its substance is not edited in place.** Rewriting the goal, constraints, or steps destroys the reasoning behind the earlier version — write a new numbered plan that supersedes it. Ticking checkboxes and appending to `Plan Changes`, `Files Changed`, `Session Summary`, `Follow-ups`, and `Risks` is always fine.

**The log is optional.** Write one only when the work spans more than one session, has blast radius outside this repo, or its rejected options carry information the commits won't show.

**Plan files are disposable history.** On completion, durable facts are promoted out of the plan's `Decisions & Commentary` section into `CLAUDE.md` as one-line gotchas; the plan file itself is then not maintained and nobody is expected to reread it. `CLAUDE.md` is the decision record — there is deliberately no `docs/adr/` or `plans/decisions/` layer in this repo.
