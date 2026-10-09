# Worktree Passport

Worktree Passport is a personal Codex skill that keeps Git worktree identity, local workspace readiness, and expected AWS/EKS runtime targets explicit. It prevents work from silently falling back to another repository, branch, AWS profile, kube context, or namespace.

## What it does

- Records project, environment, ticket, owner, and expected branch in Git's worktree-specific configuration.
- Shows a complete dry-run before creating a worktree or changing Passport metadata.
- Fast-forwards a clean primary `main` from `origin/main` before creating a `main`-based worktree.
- Checks mise trust, direnv allow state, and configured Git-ignored env symlinks.
- Verifies the selected AWS account and Kubernetes context/namespace with explicit targets.
- Verifies a Linear ticket's workspace, team, project, and team-key prefix before issue work.
- Stops on missing or mismatched targets instead of trying ambient defaults.

Passport does not create or modify AWS profiles, kubeconfig, shell startup files, hooks, tracked project files, credentials, or deployments.

## Repository layout

```text
.
├── projects.toml.example
└── worktree-passport/
    ├── SKILL.md
    ├── references/
    │   ├── linear-target.md
    │   └── project-initialization.md
    ├── scripts/
    │   └── passport.sh
    └── tests/
        └── test-passport.sh
```

`projects.toml.example` contains placeholders only. The real `projects.toml` is intentionally ignored by Git because it may contain private repository names, AWS account IDs, cluster names, and local paths.

## Install

```bash
git clone git@github.com:yungtweek/passport.git
cd passport

mkdir -p ~/.codex/skills/worktree-passport
mkdir -p ~/.codex/worktree-passport

if [ -z "$(ls -A ~/.codex/skills/worktree-passport)" ]; then
  cp -R worktree-passport/. ~/.codex/skills/worktree-passport/
else
  echo "Skill directory already contains files; review before updating."
fi

if [ ! -e ~/.codex/worktree-passport/projects.toml ]; then
  cp projects.toml.example ~/.codex/worktree-passport/projects.toml
else
  echo "Personal projects.toml already exists; it was not overwritten."
fi
```

If a real `~/.codex/worktree-passport/projects.toml` already exists, review and merge the example manually rather than overwriting it.

Start a new Codex task after installation so the skill is discovered.

## Configure a project

The simplest workflow is to open Codex in a Git repository and ask:

> Passport 초기 등록해줘

Codex discovers the repository, remote, and current branch; collects local AWS profile and kube context candidates; asks only for ambiguous target values; and shows one combined configuration and worktree-registration preview. Nothing is written until that exact plan is approved.

To configure the file manually, copy and edit the example:

```toml
[projects.example-service]
remote = "git@github.com:example/example-service.git"

[projects.example-service.environments.development]
aws_profile = "example-development"
aws_account_id = "111111111111"
aws_region = "ap-northeast-1"
eks_cluster = "example-development"
kube_context = "arn:aws:eks:ap-northeast-1:111111111111:cluster/example-development"
namespace = "example-service"

[projects.example-service.targets.linear]
workspace_id = "workspace-id"
team_id = "team-id"
team_key = "TASK"
project_id = "project-id"
project_name = "Example Project"
```

Store target names only. Never add access keys, secret keys, session tokens, SSO cache data, kubeconfig content, certificates, application secrets, or env-file contents.

Linear IDs are non-secret target identifiers. Never store a Linear API key, OAuth token, cookie, or connector credential in this file.

## Use

Inspect the current worktree:

```bash
~/.codex/skills/worktree-passport/scripts/passport.sh status
```

Verify its expected AWS and Kubernetes runtime target:

```bash
~/.codex/skills/worktree-passport/scripts/passport.sh status --runtime
```

Verify a live Linear target after obtaining its immutable IDs from the connected integration:

```bash
WORKTREE_PASSPORT_LINEAR_WORKSPACE_ID="workspace-id" \
WORKTREE_PASSPORT_LINEAR_TEAM_ID="team-id" \
WORKTREE_PASSPORT_LINEAR_PROJECT_ID="project-id" \
  ~/.codex/skills/worktree-passport/scripts/passport.sh status --external
```

The external guard fails when live IDs are omitted or do not exactly match `targets.linear`. It never falls back to another Linear workspace, team, or project.

`apply` and `remove` are dry-run operations unless `--yes` is supplied. Codex must show the complete plan and receive explicit approval before using `--yes`.

When a new worktree uses `--base main`, the dry-run includes `git pull --ff-only origin main`. The approved run performs that pull before creating the worktree and stops if the primary worktree is dirty, is not on `main`, cannot fast-forward, or contains commits not present on `origin/main`. Other base branches are not synchronized automatically, and Passport does not install Git hooks.

Typical Codex requests include:

- `TASK-123 작업을 staging 환경의 새 worktree에서 시작해줘.`
- `현재 worktree의 Passport 상태를 확인해줘.`
- `AWS/EKS 실행 대상까지 검증해줘.`
- `이 worktree의 Passport를 제거해줘.`

## Test

The test suite creates isolated temporary repositories and replaces AWS, kubectl, mise, and direnv with local test doubles. It does not use the caller's Git configuration or cloud credentials.

```bash
./worktree-passport/tests/test-passport.sh
```

## Moving to another computer

Copy or clone this repository, install the skill, and create a machine-appropriate personal `projects.toml`. Prepare AWS profiles, kube contexts, and personal env source files separately. Passport never transports credentials, kubeconfig, secrets, or Git worktree metadata between computers.
