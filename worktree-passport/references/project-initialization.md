# Initial Project Registration

Use this workflow when a project does not yet have a runtime profile in `~/.codex/worktree-passport/projects.toml`, or when its current worktree has no Passport identity. The goal is to remove manual TOML editing without treating ambient cloud defaults as expected targets.

## Discover without changing state

Start inside the project and run `scripts/passport.sh status`. Collect these values read-only:

- repository root and primary worktree
- repository directory name as the proposed project key
- exact `origin` remote URL
- current branch
- existing Passport values
- whether the proposed project key or remote already occurs in `projects.toml`
- repository-root mise config and `.envrc` presence

Project and environment keys should contain only letters, digits, `_`, or `-`, because the bundled parser addresses TOML sections by their literal path. Propose a stable sanitized key when the repository directory name contains other characters.

If the same project key exists with a different remote, or the same remote exists under another key, stop and show the conflict. Do not create a duplicate mapping automatically.

## Resolve the intended environment

Infer only a proposal from explicit user context, branch naming, or an existing project convention. If the intended environment is not unambiguous, ask for it. Never infer `prod` merely because it is the only configured or available environment.

Runtime configuration is optional for identity-only projects. If the user needs AWS or Kubernetes access, collect candidates locally:

- `aws configure list-profiles` lists profile names without selecting one.
- `kubectl config get-contexts -o name` lists local context names without selecting the current context.

Candidate listing is discovery, not target verification. Do not call STS for every profile, query every cluster, or enumerate namespaces across contexts. Ask the user to choose when more than one plausible profile or context remains. Never substitute the default AWS profile or current kube context.

After the expected AWS profile is selected:

1. Read its configured region with the selected profile explicitly. If absent, ask for the expected region.
2. Run `aws --profile <profile> --region <region> sts get-caller-identity --query Account --output text`.
3. Use that verified account ID in the proposal.

After the expected kube context and namespace are selected:

1. Confirm the selected context exists in kubeconfig.
2. Derive the EKS cluster name only when it is unambiguous from the selected context or its selected context entry; otherwise ask.
3. Verify namespace access only with `kubectl --context <context> --namespace <namespace> get namespace <namespace> -o name`.

Do not run `aws configure`, `aws eks update-kubeconfig`, `kubectl config use-context`, or any cloud mutation. A missing profile, account mismatch, missing context, or inaccessible namespace is a registration blocker, not permission to try another target.

## Build one combined preview

Prepare a proposed copy of `projects.toml` in an isolated temporary directory. Preserve all existing projects, comments, and unrelated values. Add only the new project or environment section:

```toml
[projects.<project>]
remote = "<exact-origin-url>"

[projects.<project>.environments.<environment>]
aws_profile = "<selected-profile>"
aws_account_id = "<verified-account>"
aws_region = "<expected-region>"
eks_cluster = "<expected-cluster>"
kube_context = "<selected-context>"
namespace = "<expected-namespace>"
```

Add a bootstrap section only for values that can be safely established:

- A repository `.envrc` may supply `direnv_rc = ".envrc"`.
- Never invent an env source path or inspect env contents. Add `env_links` only when the user identifies each personal source.
- Verify every target is inside the worktree and Git-ignored before proposing a link.

Run the normal `passport.sh apply ...` dry-run against the proposed temporary configuration by setting `WORKTREE_PASSPORT_CONFIG` for that process. This lets the preview include the future runtime and bootstrap values without modifying the real personal configuration.

Show one combined plan containing:

- exact `projects.toml` additions or old/new values
- repository, remote, project key, environment, owner, branch, and optional ticket
- verified AWS account and selected profile/region, when configured
- selected EKS cluster, kube context, and namespace, when configured
- mise, direnv, and env-link changes from the `apply` dry-run
- unchanged boundaries: project tracked files, shell configuration, credentials, kubeconfig, cloud resources, build, and deployment

If an existing environment would be changed, show every old/new runtime value. Do not overwrite it under a generic initialization approval.

## Apply after one explicit approval

Record a checksum of the real `projects.toml` before presenting the plan. After the user explicitly approves that exact plan:

1. Recheck the repository root, remote, branch, configuration checksum, and selected runtime identities.
2. If any value drifted, stop and show a refreshed plan instead of applying.
3. Update the real personal configuration without replacing unrelated content.
4. Run the same `passport.sh apply ... --yes` command in the target worktree.
5. Run `passport.sh status` and, when a runtime profile was added, `passport.sh status --runtime`.

The approval covers only the displayed personal configuration update, Passport Git metadata, and displayed local bootstrap actions. It does not authorize credential login or refresh, dependency installation, shell changes, commits, pushes, builds, cloud mutations, or deployments.

If the personal configuration update succeeds but Passport or bootstrap application fails, keep the successfully written configuration, report the partial result, and provide a precise recovery command. Do not delete a newly created worktree or rewrite concurrent configuration changes automatically.
