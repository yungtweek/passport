# App-managed worktrees

Use this workflow for worktrees managed by the ChatGPT/Codex desktop app. The agent calls app tools; `passport.sh` does not call them or register app attachments itself.

## Resolve and preview

1. Run Passport `status` in the source repository. Resolve the exact origin, Git common directory, project/environment, optional ticket, owner, intended branch, and absolute personal config and script paths. Existing personal targets remain unchanged unless project registration was separately requested.
2. Resolve the intended base to a commit SHA. Pass that SHA as `ref`; the app tool otherwise defaults to the remote default branch, and does not copy uncommitted changes. Do not promise to carry local edits through this workflow.
3. If a new worktree was not explicitly requested, call `list_artifacts` and prefer a suitable active worktree attached to this task. Do not adopt another task's checkout or manually attach an arbitrary Git worktree.
4. Inspect the selected commit's mise config, `.envrc`, ignore rules, and any existing `.worktreeinclude`. Check configured env sources by existence and path only. A source under the original checkout is valid if explicitly configured, but depends on that checkout remaining available. Inspect tracked bootstrap code for relative sibling paths or absolute checkout references when needed; do not print or source env-file contents. Stop on an unresolved dependency rather than guessing another env source.
5. Show one plan: managed creation, repository, base SHA, app-selected path/name, intended branch, Passport values, exact personal env sources and worktree-relative targets, and anticipated mise/direnv actions. State that the actual path and checkout are verified after app creation. Include any configured app setup script effects in the plan; do not enable extra setup scripts or add `.worktreeinclude` automatically.

The plan authorizes the app to allocate its checkout path. Do not require it to be a sibling of the original repository or include the ticket in its directory name. Require the ticket in the intended branch. If project/environment, base, branch, env mapping, or executable bootstrap content changes, refresh the plan before those changes are applied. Honor explicit authorization already provided for this workflow.

## Create, register, verify

1. Call `create_worktree` with `allowAsync: true`, the explicit base SHA as `ref`, and an optional short lowercase app-compatible name. A name is a label, not a branch or promised filesystem path. If the tool is unavailable, report that managed creation is unavailable; do not silently run `git worktree add`.
2. For a pending result, use `get_worktree_creation_status` until completed or failed. If creation succeeded but attachment failed, recover with `attach_worktree` using the returned workspace directory. Preserve any created checkout on failure.
3. Use the returned **workspace directory**, not the worktree container directory or the original checkout. Resolve it once with `cd <returned-workspace> && pwd -P`, then use that physical absolute path for all following working directories and direnv/mise commands. On macOS, `/var/...` and `/private/var/...` can refer to the same directory but have different direnv allow identities. Preserve the app's attachment identity separately for lifecycle tools. The calling task stays in its existing checkout; set the working directory on every following operation. Confirm the exact remote, physical Git common directory, and HEAD commit match the source and approved base. Run Passport `status` there.
4. Run the actual `apply` dry-run inside that checkout with the same absolute personal config. A fresh managed worktree normally has detached HEAD. Use `--new-branch` to preview and create the intended branch as part of the same application:

   ```bash
   WORKTREE_PASSPORT_CONFIG="/absolute/personal/projects.toml" \
     /absolute/skill/scripts/passport.sh apply \
       --project example-service --environment development --owner codex \
       --ticket TASK-123 --expected-branch codex/TASK-123-feature --new-branch
   ```

   Run this command with the returned workspace as its working directory. Add `--yes` after its branch and bootstrap actions match the authorized plan. Do not use `--create`, `--worktree`, or `--base` for a checkout already created by the app. `--new-branch` requires detached HEAD and an unused valid branch name; existing named worktrees use ordinary `apply` with their actual approved branch.
5. Confirm the branch, Passport values, and every env link in the actual checkout. Env links are prepared before mise trust or direnv allow. Check that direnv/mise paths and hashes belong to this checkout. Only run a loading check such as `direnv exec <workspace> true` if its repository code execution was included in the bootstrap authorization; avoid commands that print the environment.
6. Run `status --runtime` or the Linear guard only when those targets are required. Existing personal target mappings are reused by project/environment; a different worktree path must not cause discovery of a different cloud or Linear target.

If bootstrap fails after creation, report the actual path, completed branch/metadata changes, and failed action. Preserve the checkout and provide a recovery command targeting it. Do not continue application work with unresolved required env links.

## Environment paths and copied files

- `source = "~/..."` resolves from the user's home. An absolute source stays fixed. A relative source resolves from the directory of the selected personal `projects.toml`, never the original or managed checkout.
- Targets such as `service/.env` resolve from the returned workspace and must be Git-ignored. Symlinked parent directories are rejected, so an env link cannot land outside that workspace.
- Missing sources, non-ignored targets, occupied targets, and links to another source stop application. An already-correct link is reused. Passport never reads env contents to compare files.
- App setup or `.worktreeinclude` may already have copied an ignored `.env`. If that conflicts with a configured link, preserve it and report the conflict. Do not replace it, switch environments, or remove `env_links` to bypass the check. When no link is configured, do not invent one; verify the requested project's existing loading arrangement separately.
- A new checkout or restored checkout needs a fresh bootstrap check. Ignored files and symlinks may not survive app archival/restoration. Recreate approved links from their stable personal sources after inspection; never delete those sources.

## Lifecycle

Use `list_artifacts` to obtain the exact worktree identity and the app's `archive_worktree`/`restore_worktree` tools for requested cleanup/restoration. Do not use raw `git worktree remove`, `rm`, or `prune` on managed checkouts. Preserve necessary ignored files separately before archival. After restoration or Handoff, inspect the actual checkout again: branch and worktree-local Passport metadata may differ, and env loading must be verified there.
