# Linear Target Guard

Use this guard whenever a Passport-managed worktree will read, create, update, or move a Linear issue.

## Configuration

Store one expected Linear target for the repository in the personal configuration, separate from runtime environments:

```toml
[projects.example-service.targets.linear]
workspace_id = "workspace-id"
team_id = "team-id"
team_key = "TASK"
project_id = "project-id"
project_name = "Example Project"
```

Use immutable workspace, team, and project IDs for verification. Keep the team key and project name only for readable output and ticket-prefix validation. Do not store API keys, OAuth tokens, cookies, or connector credentials.

The worktree continues to store only `passport.ticket`, such as `TASK-123`. The default Linear target is derived from `passport.project`. Do not duplicate a repository's single expected workspace/team/project into every worktree.

## Read-only verification

1. Run `passport.sh status` and require the configured ticket prefix to match `team_key`.
2. Query the connected Linear integration read-only for the active workspace, selected team, and selected project. Obtain their immutable IDs; do not select a default or first result silently.
3. Pass those returned IDs explicitly to the deterministic guard:

```bash
WORKTREE_PASSPORT_LINEAR_WORKSPACE_ID="<live-workspace-id>" \
WORKTREE_PASSPORT_LINEAR_TEAM_ID="<live-team-id>" \
WORKTREE_PASSPORT_LINEAR_PROJECT_ID="<live-project-id>" \
  ~/.codex/skills/worktree-passport/scripts/passport.sh status --external
```

`status --external` succeeds only when the Git remote, ticket prefix, workspace ID, team ID, and project ID all match the configured target. Missing live IDs or any mismatch is a target-verification failure. Do not retry with another workspace, team, project, or issue prefix.

If no Linear integration is available, report that live verification cannot be completed. Do not treat local configuration alone as authorization to perform an external mutation.

## Mutation boundary

Target verification is read-only. Creating, updating, moving, assigning, or commenting on a Linear issue is a separate external change and requires authorization appropriate to the user's request. Before mutation, show the verified workspace/team/project, issue identifier, and intended changes.

After mutation, read the issue back from the same explicit target and report its final identifier, state, project, and URL. Never store the Linear token or response payload in Passport.

## Multiple Linear projects

The current schema defines one default Linear project per repository. If a repository needs multiple projects, do not overwrite the default or guess from the issue. Extend the schema with an explicit, reviewed project-selection design before storing a per-worktree project choice.
