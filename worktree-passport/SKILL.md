---
name: worktree-passport
description: Create app-managed worktrees and register or verify their Passport identity, local bootstrap readiness, AWS/EKS runtime targets, and Linear targets. Use for Passport registration, worktree creation or inspection, and resuming work across repositories.
---

# Worktree Passport

Use the bundled `scripts/passport.sh` to establish which repository, worktree, branch, project, environment, and runtime target a task belongs to.

## Start with inspection

Run `scripts/passport.sh status` before proposing worktree changes. Add `--runtime` only when the task needs AWS or Kubernetes access. For Linear issue work, read [references/linear-target.md](references/linear-target.md) and use `--external` with the live workspace, team, and project IDs returned by the connected Linear integration.

If Passport is absent, infer a proposal from the repository, branch, task, and `~/.codex/worktree-passport/projects.toml`, but do not write it yet. Do not infer a runtime target that is not declared in that file.

## Worktree creation

For new worktrees, use the ChatGPT/Codex desktop app's managed worktree tools. Read [references/managed-worktrees.md](references/managed-worktrees.md) for creation, detached-HEAD registration, environment-path checks, and cleanup. The app chooses the checkout path; Passport records identity and prepares local env links in the returned workspace. The shell script's `--create` mode remains available only for explicitly requested standalone Git worktrees.

When work begins in an app-created worktree, register that checkout rather than creating another. Resolve the project from existing Passport values or the exact remote and personal project mapping, not from an app-generated directory name.

Resolve the bundled script and personal configuration to absolute paths before changing directories. Keep the same absolute `WORKTREE_PASSPORT_CONFIG` for preflight, application, and verification. Env sources are personal paths; relative sources are anchored to the personal config directory, and targets are anchored to the actual worktree. Do not automatically register additional projects.

Resolve the returned workspace to its physical absolute path (`pwd -P`) and use it consistently, including `direnv exec`. Path aliases can have different direnv allow identities even when they refer to the same files.

## Initial project registration

When the user asks to initialize, onboard, or automatically register a project, read [references/project-initialization.md](references/project-initialization.md) and follow it. Automate repository discovery and candidate collection, but require the user to choose any ambiguous environment, AWS profile, kube context, or namespace. Preview the personal configuration update and worktree registration together, then apply both after one explicit approval.

## Preview and approval

Before creating a worktree, recording Passport values, trusting a mise config, allowing direnv, or creating configured env symlinks:

1. Run `passport.sh apply ...` without `--yes` and show the complete preview. For an app-managed creation, use the staged preview and actual-path checks in [references/managed-worktrees.md](references/managed-worktrees.md).
2. Summarize the repository, base branch, new branch, worktree path, ticket, owner, environment, expected runtime target, Git changes, local bootstrap changes, and unchanged boundaries.
3. Wait for explicit approval of that exact plan. Do not reuse approval from an earlier or different plan.
4. If repository, path, branch, ticket, environment, or bootstrap plan changes, show the refreshed preview and ask again.
5. After approval, repeat the same command with `--yes`.

One approval may cover the previewed worktree creation, non-secret Git metadata, mise trust, direnv allow, and env symlinks. It does not cover dependency installation, shell changes, cloud configuration, builds, pushes, deployments, commits, or PRs unless the user's request separately authorizes them.

## Runtime guard

Combine `passport.project` and `passport.environment` with the personal configuration. Before any cloud-resource conclusion, run `status --runtime` and require it to succeed.

- Always pass the declared AWS profile and region explicitly.
- Always pass the declared kube context and namespace explicitly.
- Never fall back to the default AWS profile, current kube context, another cluster, or another namespace.
- Treat target-verification failure separately from a verified target containing no resource.
- Never run `aws configure`, `aws eks update-kubeconfig`, or `kubectl config use-context` as part of Passport.

## External workspace guard

Keep the expected Linear workspace, team, and project in the personal `projects.toml`; keep only the issue identifier in `passport.ticket`. Before reading or mutating Linear issues, verify the live connected target using the workflow in [references/linear-target.md](references/linear-target.md). Never fall back to another workspace, team, or project, and never store a Linear token in Passport.

## Boundaries and verification

Do not add Passport files to project repositories, edit tracked project files, install hooks, edit shell startup files, or store credentials, tokens, kubeconfig bodies, or env contents.

After applying, run `passport.sh status`; use `status --runtime` only when runtime access is needed. Report the actual worktree path, branch, Passport values, bootstrap result, and any partial failure. If a worktree was created but a later step failed, preserve it and provide explicit recovery commands instead of deleting it automatically.

For removal, preview `passport.sh remove` first and use `remove --yes` only after approval. Removal clears only the five Passport keys; it preserves the worktree, branch, repository-level worktree config, and personal runtime configuration.
