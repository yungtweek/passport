#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PASSPORT=$(cd "$SCRIPT_DIR/../scripts" && pwd -P)/passport.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worktree-passport-test.XXXXXX")
PASS=0
FAIL=0
REAL_DIRENV=$(command -v direnv 2>/dev/null || true)

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT INT TERM

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }
assert_success() { local name=$1; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }
assert_failure() { local name=$1; shift; if "$@"; then not_ok "$name"; else ok "$name"; fi; }
contains() { printf '%s\n' "$1" | grep -F "$2" >/dev/null 2>&1; }
not_contains() { ! contains "$1" "$2"; }

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export WORKTREE_PASSPORT_CONFIG="$TEST_ROOT/projects.toml"
export MOCK_LOG="$TEST_ROOT/mock.log"
export MOCK_MISE_VERSION=2026.8.0
export MOCK_MISE_TRUSTED=false
export MOCK_DIRENV_ALLOWED=false
export MOCK_AWS_PROFILES=expected-profile
export MOCK_AWS_ACCOUNT=111111111111
export MOCK_KUBE_CONTEXT=expected-context
export MOCK_KUBE_NAMESPACE=expected-namespace

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/personal"

cat >"$TEST_ROOT/bin/mise" <<'EOF'
#!/usr/bin/env bash
printf 'mise %s\n' "$*" >>"$MOCK_LOG"
case "${1:-}" in
  --version) printf '%s\n' "$MOCK_MISE_VERSION" ;;
  trust)
    if [ "${2:-}" = --show ]; then
      if [ "$MOCK_MISE_TRUSTED" = true ] || [ -f "${MOCK_LOG}.mise-trusted" ]; then printf '%s\n' "${3:-trusted-config}"; else printf 'mise No trusted config files found.\n'; fi
    else export MOCK_MISE_TRUSTED=true; printf '%s\n' "${2:-}" >"${MOCK_LOG}.mise-trusted"; fi ;;
esac
EOF

cat >"$TEST_ROOT/bin/direnv" <<'EOF'
#!/usr/bin/env bash
printf 'direnv %s\n' "$*" >>"$MOCK_LOG"
case "${1:-}" in
  status)
    if [ "$MOCK_DIRENV_ALLOWED" = true ] || [ -f "${MOCK_LOG}.direnv-allowed" ]; then printf 'Found RC allowed 0\n'; else printf 'Found RC allowed 1\n'; fi ;;
  allow)
    if [ -n "${MOCK_REQUIRED_ENV_TARGET:-}" ] && [ ! -f "$MOCK_REQUIRED_ENV_TARGET" ]; then
      printf 'required env target missing before direnv allow\n' >&2
      exit 1
    fi
    : >"${MOCK_LOG}.direnv-allowed" ;;
esac
EOF

cat >"$TEST_ROOT/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = configure ] && [ "${2:-}" = list-profiles ]; then printf '%s\n' "$MOCK_AWS_PROFILES"; exit 0; fi
printf '%s\n' "$MOCK_AWS_ACCOUNT"
EOF

cat >"$TEST_ROOT/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$MOCK_LOG"
case " $* " in
  *" --context $MOCK_KUBE_CONTEXT --namespace $MOCK_KUBE_NAMESPACE config get-contexts $MOCK_KUBE_CONTEXT "*)
    printf '%s\n' "$MOCK_KUBE_CONTEXT"
    exit 0 ;;
esac
case " $* " in
  *" config get-contexts "*)
  exit 0
  ;;
esac
case " $* " in
  *" --context $MOCK_KUBE_CONTEXT --namespace $MOCK_KUBE_NAMESPACE get namespace $MOCK_KUBE_NAMESPACE "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/"*
export PATH="$TEST_ROOT/bin:$PATH"

REPO="$TEST_ROOT/example-service"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" remote add origin git@github.com:example/example-service.git
printf 'service/.env\n' >"$REPO/.gitignore"
printf 'base\n' >"$REPO/tracked.txt"
git -C "$REPO" add .gitignore tracked.txt
git -C "$REPO" commit -q -m init

cat >"$WORKTREE_PASSPORT_CONFIG" <<EOF
[projects.example-service]
remote = "git@github.com:example/example-service.git"

[projects.example-service.environments.development]
aws_profile = "expected-profile"
aws_account_id = "111111111111"
aws_region = "ap-northeast-1"
eks_cluster = "expected-cluster"
kube_context = "expected-context"
namespace = "expected-namespace"

[projects.example-service.environments.development.bootstrap]
direnv_rc = ".envrc"
env_links = [
  { source = "$TEST_ROOT/personal/service.env", target = "service/.env" }
]
EOF

run_in_repo() { (cd "$REPO" && "$PASSPORT" "$@"); }

out=$(run_in_repo status 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'Passport: not configured' && ok 'status is read-only and succeeds without Passport' || not_ok 'status is read-only and succeeds without Passport'
[ "$(git -C "$REPO" status --porcelain)" = '' ] && ok 'status does not change tracked files' || not_ok 'status does not change tracked files'

before=$(git -C "$REPO" config --local --list)
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main 2>&1); rc=$?
after=$(git -C "$REPO" config --local --list)
[ "$rc" -ne 0 ] && contains "$out" 'configured direnv rc does not exist' && [ "$before" = "$after" ] && ok 'bootstrap preflight fails closed before Git mutation' || not_ok 'bootstrap preflight fails closed before Git mutation'

printf 'export TEST_ONLY=1\n' >"$REPO/.envrc"
printf '[tools]\nnode = "22"\n' >"$REPO/.mise.toml"
printf 'do-not-print-this-secret\n' >"$TEST_ROOT/personal/service.env"
git -C "$REPO" add .envrc .mise.toml
git -C "$REPO" commit -q -m envrc

before=$(git -C "$REPO" config --local --list)
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main 2>&1); rc=$?
after=$(git -C "$REPO" config --local --list)
[ "$rc" -eq 0 ] && [ "$before" = "$after" ] && contains "$out" 'Dry run only' && not_contains "$out" 'do-not-print-this-secret' && ok 'apply without --yes is a secret-safe dry run' || not_ok 'apply without --yes is a secret-safe dry run'
[ ! -e "$REPO/service/.env" ] && [ ! -f "${MOCK_LOG}.direnv-allowed" ] && [ ! -f "${MOCK_LOG}.mise-trusted" ] && ok 'dry run does not trust, allow, or link' || not_ok 'dry run does not trust, allow, or link'

out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-1 --expected-branch main 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" "ticket 'TASK-1' must appear" && ok 'ticket must appear in branch' || not_ok 'ticket must appear in branch'

MOCK_DIRENV_ALLOWED=false out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main --yes 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$REPO" config --get extensions.worktreeConfig)" = true ] && [ "$(git -C "$REPO" config --worktree --get passport.project)" = example-service ] && [ "$(git -C "$REPO" config --worktree --get passport.environment)" = development ] && [ "$(git -C "$REPO" config --worktree --get passport.owner)" = codex ] && [ "$(git -C "$REPO" config --worktree --get passport.expected-branch)" = main ] && ok 'apply --yes enables worktree config and writes Passport' || { printf '%s\n' "$out"; not_ok 'apply --yes enables worktree config and writes Passport'; }
[ -L "$REPO/service/.env" ] && [ "$(readlink "$REPO/service/.env")" = "$TEST_ROOT/personal/service.env" ] && ok 'approved bootstrap creates only configured ignored symlink' || not_ok 'approved bootstrap creates only configured ignored symlink'
[ -f "${MOCK_LOG}.direnv-allowed" ] && ok 'approved bootstrap allows blocked direnv' || not_ok 'approved bootstrap allows blocked direnv'
[ "$(git -C "$REPO" status --porcelain)" = '' ] && ok 'approved apply leaves tracked project files unchanged' || not_ok 'approved apply leaves tracked project files unchanged'

: >"$MOCK_LOG"
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main --yes 2>&1); rc=$?
log=$(cat "$MOCK_LOG")
[ "$rc" -eq 0 ] && not_contains "$log" "mise trust $REPO/.mise.toml" && not_contains "$log" "direnv allow $REPO" && ok 'trusted mise and allowed direnv are not applied again' || not_ok 'trusted mise and allowed direnv are not applied again'
not_contains "$log" 'whitelist' && ok 'bootstrap never adds a broad direnv whitelist' || not_ok 'bootstrap never adds a broad direnv whitelist'

out=$(run_in_repo status 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'Expected branch match: yes' && ok 'status verifies expected branch' || not_ok 'status verifies expected branch'
git -C "$REPO" config --worktree passport.expected-branch wrong-branch
assert_failure 'status fails on branch mismatch' run_in_repo status
git -C "$REPO" config --worktree passport.expected-branch main

: >"$MOCK_LOG"
config_before=$(shasum -a 256 "$WORKTREE_PASSPORT_CONFIG" | awk '{print $1}')
out=$(run_in_repo status --runtime 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'AWS caller account: 111111111111 [match]' && contains "$out" 'namespace access: verified' && ok 'runtime guard verifies configured AWS and Kubernetes targets' || { printf '%s\n' "$out"; not_ok 'runtime guard verifies configured AWS and Kubernetes targets'; }
log=$(cat "$MOCK_LOG")
contains "$log" 'aws --profile expected-profile --region ap-northeast-1 sts get-caller-identity' && contains "$log" 'kubectl --context expected-context --namespace expected-namespace get namespace expected-namespace' && not_contains "$log" 'use-context' && ok 'runtime commands use explicit targets and never switch context' || not_ok 'runtime commands use explicit targets and never switch context'
if printf '%s\n' "$log" | awk '/^kubectl / && $0 !~ /--context expected-context --namespace expected-namespace/ { bad=1 } END { exit bad }'; then ok 'every kubectl invocation carries the expected context and namespace'; else not_ok 'every kubectl invocation carries the expected context and namespace'; fi
config_after=$(shasum -a 256 "$WORKTREE_PASSPORT_CONFIG" | awk '{print $1}')
[ "$config_before" = "$config_after" ] && not_contains "$log" 'configure set' && not_contains "$log" 'update-kubeconfig' && ok 'runtime verification does not modify AWS, kubeconfig, or personal config' || not_ok 'runtime verification does not modify AWS, kubeconfig, or personal config'

: >"$MOCK_LOG"
export MOCK_AWS_PROFILES=other-profile
out=$(run_in_repo status --runtime 2>&1); rc=$?
log=$(cat "$MOCK_LOG")
[ "$rc" -ne 0 ] && contains "$out" 'no fallback attempted' && not_contains "$log" 'sts get-caller-identity' && ok 'missing AWS profile fails without default fallback' || not_ok 'missing AWS profile fails without default fallback'
export MOCK_AWS_PROFILES=expected-profile

: >"$MOCK_LOG"
export MOCK_AWS_ACCOUNT=999999999999
out=$(run_in_repo status --runtime 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'AWS account mismatch' && not_contains "$(cat "$MOCK_LOG")" 'kubectl' && ok 'AWS account mismatch stops before Kubernetes' || not_ok 'AWS account mismatch stops before Kubernetes'
export MOCK_AWS_ACCOUNT=111111111111

: >"$MOCK_LOG"
export MOCK_KUBE_CONTEXT=other-context
out=$(run_in_repo status --runtime 2>&1); rc=$?
log=$(cat "$MOCK_LOG")
[ "$rc" -ne 0 ] && contains "$out" 'current context was not used' && not_contains "$log" ' get namespace ' && ok 'missing kube context fails without namespace or cluster fallback' || not_ok 'missing kube context fails without namespace or cluster fallback'
export MOCK_KUBE_CONTEXT=expected-context

cp "$WORKTREE_PASSPORT_CONFIG" "$TEST_ROOT/projects.before-linear.toml"
cat >>"$WORKTREE_PASSPORT_CONFIG" <<'EOF'

[projects.example-service.targets.linear]
workspace_id = "workspace-123"
team_id = "team-123"
team_key = "TASK"
project_id = "project-123"
project_name = "Example Project"
EOF
git -C "$REPO" config --worktree passport.ticket TASK-123

out=$(run_in_repo status 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'Linear target (expected)' && contains "$out" 'ticket team match: yes' && ok 'status resolves Linear target from project and ticket' || not_ok 'status resolves Linear target from project and ticket'

out=$(run_in_repo status --external 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'live Linear workspace/team/project IDs were not supplied' && contains "$out" 'no fallback attempted' && ok 'external guard fails closed without live Linear IDs' || not_ok 'external guard fails closed without live Linear IDs'

export WORKTREE_PASSPORT_LINEAR_WORKSPACE_ID=workspace-123
export WORKTREE_PASSPORT_LINEAR_TEAM_ID=team-123
export WORKTREE_PASSPORT_LINEAR_PROJECT_ID=project-123
out=$(run_in_repo status --external 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'live Linear identity: verified' && ok 'external guard verifies exact live Linear target IDs' || not_ok 'external guard verifies exact live Linear target IDs'

export WORKTREE_PASSPORT_LINEAR_TEAM_ID=other-team
out=$(run_in_repo status --external 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'Linear team mismatch' && contains "$out" 'no fallback attempted' && ok 'Linear team mismatch fails without fallback' || not_ok 'Linear team mismatch fails without fallback'
export WORKTREE_PASSPORT_LINEAR_TEAM_ID=team-123

git -C "$REPO" config --worktree passport.ticket OTHER-123
out=$(run_in_repo status 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'ticket team match: no' && ok 'ticket prefix mismatch fails against configured Linear team' || not_ok 'ticket prefix mismatch fails against configured Linear team'

git -C "$REPO" config --worktree --unset-all passport.ticket
unset WORKTREE_PASSPORT_LINEAR_WORKSPACE_ID WORKTREE_PASSPORT_LINEAR_TEAM_ID WORKTREE_PASSPORT_LINEAR_PROJECT_ID
cp "$TEST_ROOT/projects.before-linear.toml" "$WORKTREE_PASSPORT_CONFIG"

out=$(run_in_repo remove 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$REPO" config --worktree --get passport.project)" = example-service ] && contains "$out" 'Dry run only' && ok 'remove without --yes changes nothing' || not_ok 'remove without --yes changes nothing'
head_before=$(git -C "$REPO" rev-parse HEAD)
run_in_repo remove --yes >/dev/null
[ -z "$(git -C "$REPO" config --worktree --get passport.project 2>/dev/null || true)" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ] && [ -d "$REPO" ] && ok 'remove --yes clears only Passport keys' || not_ok 'remove --yes clears only Passport keys'

NEW_WT="$TEST_ROOT/example-service-TASK-2-feature"
out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-2 --expected-branch codex/TASK-2-feature --create --worktree "$NEW_WT" --base main 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$NEW_WT" ] && contains "$out" 'git worktree add' && ok 'new-worktree apply previews without creating' || not_ok 'new-worktree apply previews without creating'

out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-2 --expected-branch codex/TASK-2-feature --create --worktree "$NEW_WT" --base main --yes 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -d "$NEW_WT" ] && [ "$(git -C "$NEW_WT" branch --show-current)" = codex/TASK-2-feature ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.project)" = example-service ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.environment)" = development ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.ticket)" = TASK-2 ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.owner)" = codex ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.expected-branch)" = codex/TASK-2-feature ] && ok 'approved create makes sibling worktree and all five Passport values' || { printf '%s\n' "$out"; not_ok 'approved create makes sibling worktree and all five Passport values'; }

assert_failure 'existing worktree path or branch is never overwritten' run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-2 --expected-branch codex/TASK-2-feature --create --worktree "$NEW_WT" --base main
assert_failure 'ticket must appear in new worktree directory' run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-3 --expected-branch codex/TASK-3-feature --create --worktree "$TEST_ROOT/example-service-feature" --base main
assert_failure 'worktree outside primary repository siblings is rejected' run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-4 --expected-branch codex/TASK-4-feature --create --worktree "$TEST_ROOT/nested/example-service-TASK-4-feature" --base main

cp "$WORKTREE_PASSPORT_CONFIG" "$TEST_ROOT/projects.good.toml"
rm -f "$REPO/service/.env"
mv "$TEST_ROOT/personal/service.env" "$TEST_ROOT/personal/service.env.saved"
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'env source is missing' && [ ! -e "$REPO/service/.env" ] && ok 'missing env source creates neither symlink nor empty file' || not_ok 'missing env source creates neither symlink nor empty file'
mv "$TEST_ROOT/personal/service.env.saved" "$TEST_ROOT/personal/service.env"

sed 's#target = "service/.env"#target = "visible.env"#' "$TEST_ROOT/projects.good.toml" >"$WORKTREE_PASSPORT_CONFIG"
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'env target is not Git-ignored' && [ ! -e "$REPO/visible.env" ] && ok 'non-ignored env target is rejected' || not_ok 'non-ignored env target is rejected'

cp "$TEST_ROOT/projects.good.toml" "$WORKTREE_PASSPORT_CONFIG"
mkdir -p "$REPO/service"
printf 'existing-value\n' >"$REPO/service/.env"
out=$(run_in_repo apply --project example-service --environment development --owner codex --expected-branch main 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'will not be overwritten' && [ "$(cat "$REPO/service/.env")" = existing-value ] && ok 'existing env target is never overwritten' || not_ok 'existing env target is never overwritten'
rm -f "$REPO/service/.env"

export MOCK_MISE_VERSION=2026.1.6
out=$(run_in_repo status 2>&1)
contains "$out" 'worktree trust sharing: unsupported' && ok 'old mise version is identified' || not_ok 'old mise version is identified'
export MOCK_MISE_VERSION=2026.8.0
out=$(run_in_repo status 2>&1)
contains "$out" 'worktree trust sharing: supported' && ok 'new mise version is identified' || not_ok 'new mise version is identified'

# Exercise the app layout using an isolated detached Git checkout, not a live
# app tool. The random container and repository directory have no ticket.
MANAGED="$TEST_ROOT/app worktrees/random/example-service"
mkdir -p "$(dirname "$MANAGED")" "$TEST_ROOT/personal config" "$TEST_ROOT/local tools"
git -C "$REPO" worktree add -q --detach "$MANAGED" main
cp "$PASSPORT" "$TEST_ROOT/local tools/passport.sh"
sed "s#source = \"$TEST_ROOT/personal/service.env\"#source = \"../personal/service.env\"#" "$TEST_ROOT/projects.good.toml" >"$TEST_ROOT/personal config/projects.toml"
MANAGED_CONFIG="$TEST_ROOT/personal config/projects.toml"
run_in_managed() { (cd "$MANAGED" && WORKTREE_PASSPORT_CONFIG="$MANAGED_CONFIG" "$PASSPORT" "$@"); }
managed_apply() { run_in_managed apply --project example-service --environment development --owner codex --ticket TASK-50 --expected-branch codex/TASK-50-managed "$@"; }

before=$(git -C "$MANAGED" config --local --list)
head_before=$(git -C "$MANAGED" rev-parse HEAD)
out=$(managed_apply --new-branch 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'switch -c' && [ -z "$(git -C "$MANAGED" branch --show-current)" ] && ! git -C "$MANAGED" show-ref --verify --quiet refs/heads/codex/TASK-50-managed && [ ! -e "$MANAGED/service/.env" ] && [ "$before" = "$(git -C "$MANAGED" config --local --list)" ] && ok 'managed dry run previews branch and env links without mutation' || { printf '%s\n' "$out"; not_ok 'managed dry run previews branch and env links without mutation'; }

assert_failure 'detached registration requires explicit branch creation' managed_apply
assert_failure 'managed registration rejects an existing branch' run_in_managed apply --project example-service --environment development --owner codex --expected-branch main --new-branch
assert_failure 'managed registration rejects an invalid branch' run_in_managed apply --project example-service --environment development --owner codex --expected-branch 'bad..branch' --new-branch
assert_failure 'managed branch creation cannot also create a standalone worktree' managed_apply --new-branch --create --worktree "$TEST_ROOT/unused-TASK-50" --base main

# Missing sources must fail before creating a branch or writing metadata.
mv "$TEST_ROOT/personal/service.env" "$TEST_ROOT/personal/service.env.saved"
out=$(managed_apply --new-branch --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ -z "$(git -C "$MANAGED" branch --show-current)" ] && [ -z "$(git -C "$MANAGED" config --worktree --get passport.project 2>/dev/null || true)" ] && ok 'managed bootstrap failure preserves detached HEAD and metadata' || not_ok 'managed bootstrap failure preserves detached HEAD and metadata'
mv "$TEST_ROOT/personal/service.env.saved" "$TEST_ROOT/personal/service.env"

mkdir -p "$MANAGED/service"
printf 'copied-by-app\n' >"$MANAGED/service/.env"
copied_before=$(shasum -a 256 "$MANAGED/service/.env" | awk '{print $1}')
out=$(managed_apply --new-branch --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'will not be overwritten' && [ "$copied_before" = "$(shasum -a 256 "$MANAGED/service/.env" | awk '{print $1}')" ] && [ -z "$(git -C "$MANAGED" branch --show-current)" ] && ok 'app-copied env conflict is preserved before branch creation' || not_ok 'app-copied env conflict is preserved before branch creation'
rm -f "$MANAGED/service/.env"

# Relative script and config invocations must remain valid after apply cd.
rm -f "${MOCK_LOG}.direnv-allowed"
export MOCK_DIRENV_ALLOWED=false
export MOCK_REQUIRED_ENV_TARGET="$MANAGED/service/.env"
out=$(cd "$MANAGED" && WORKTREE_PASSPORT_CONFIG="../../../personal config/projects.toml" "../../../local tools/passport.sh" apply --project example-service --environment development --owner codex --ticket TASK-50 --expected-branch codex/TASK-50-managed --new-branch --yes 2>&1); rc=$?
unset MOCK_REQUIRED_ENV_TARGET
[ "$rc" -eq 0 ] && [ "$(git -C "$MANAGED" branch --show-current)" = codex/TASK-50-managed ] && [ "$(git -C "$MANAGED" rev-parse HEAD)" = "$head_before" ] && contains "$out" 'Applied. Verification:' && contains "$out" '[linked]' && [ "$MANAGED/service/.env" -ef "$TEST_ROOT/personal/service.env" ] && ok 'managed registration resolves relative config and source with spaces across cd' || { printf '%s\n' "$out"; not_ok 'managed registration resolves relative config and source with spaces across cd'; }
[ -f "${MOCK_LOG}.direnv-allowed" ] && ok 'env link exists before direnv allow' || not_ok 'env link exists before direnv allow'
[ "$(git -C "$MANAGED" config --worktree --get passport.ticket)" = TASK-50 ] && [ -z "$(git -C "$REPO" config --worktree --get passport.project 2>/dev/null || true)" ] && [ "$(git -C "$REPO" branch --show-current)" = main ] && [ "$(git -C "$MANAGED" status --porcelain)" = '' ] && ok 'managed Passport is worktree-local and leaves source checkout unchanged' || not_ok 'managed Passport is worktree-local and leaves source checkout unchanged'
assert_failure 'new-branch does not switch an existing named worktree' managed_apply --new-branch

config_before=$(shasum -a 256 "$MANAGED_CONFIG" | awk '{print $1}')
out=$(cd "$MANAGED/service" && WORKTREE_PASSPORT_CONFIG="$MANAGED_CONFIG" "$PASSPORT" status --runtime 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" '[linked]' && contains "$out" 'AWS caller account: 111111111111 [match]' && [ "$config_before" = "$(shasum -a 256 "$MANAGED_CONFIG" | awk '{print $1}')" ] && ok 'nested managed cwd uses the same personal source and runtime targets' || { printf '%s\n' "$out"; not_ok 'nested managed cwd uses the same personal source and runtime targets'; }

# Reach the isolated fixture through ~/ without changing HOME or its files.
home_source="~/../../${TEST_ROOT#/}/personal/service.env"
sed "s#source = \"../personal/service.env\"#source = \"$home_source\"#" "$MANAGED_CONFIG" >"$TEST_ROOT/tilde.toml"
rm -f "$MANAGED/service/.env"
out=$(cd "$MANAGED" && WORKTREE_PASSPORT_CONFIG="$TEST_ROOT/tilde.toml" "$PASSPORT" apply --project example-service --environment development --owner codex --ticket TASK-50 --expected-branch codex/TASK-50-managed --yes 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(readlink "$MANAGED/service/.env")" = "$HOME/${home_source#'~/'}" ] && [ "$MANAGED/service/.env" -ef "$TEST_ROOT/personal/service.env" ] && not_contains "$out" 'do-not-print-this-secret' && ok 'tilde env source resolves to home without literal tilde or secret output' || { printf '%s\n' "$out"; not_ok 'tilde env source resolves to home without literal tilde or secret output'; }
out=$(cd "$MANAGED" && WORKTREE_PASSPORT_CONFIG="$TEST_ROOT/tilde.toml" "$PASSPORT" apply --project example-service --environment development --owner codex --expected-branch codex/TASK-50-managed --yes 2>&1); rc=$?
[ "$rc" -eq 0 ] && contains "$out" 'env link already correct' && ok 'correct home-based link is reused' || not_ok 'correct home-based link is reused'

mv "$TEST_ROOT/personal/service.env" "$TEST_ROOT/personal/service.env.saved"
out=$(cd "$MANAGED" && WORKTREE_PASSPORT_CONFIG="$TEST_ROOT/tilde.toml" "$PASSPORT" status 2>&1)
contains "$out" '[source missing]' && ok 'status identifies a broken previously-correct env link' || not_ok 'status identifies a broken previously-correct env link'
mv "$TEST_ROOT/personal/service.env.saved" "$TEST_ROOT/personal/service.env"

rm -f "$MANAGED/service/.env"
rmdir "$MANAGED/service"
mkdir -p "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$MANAGED/service"
out=$(managed_apply --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && contains "$out" 'invalid env target path' && [ ! -e "$TEST_ROOT/outside/.env" ] && ok 'symlinked env parent cannot redirect a managed link outside checkout' || not_ok 'symlinked env parent cannot redirect a managed link outside checkout'

# Optional live loading check: only known synthetic envrc/env content, with
# isolated direnv config and allow storage. No user credentials or rc are read.
if [ -n "$REAL_DIRENV" ]; then
  mkdir -p "$TEST_ROOT/live-bin" "$TEST_ROOT/live personal" "$TEST_ROOT/live-config" "$TEST_ROOT/live-data"
  ln -s "$REAL_DIRENV" "$TEST_ROOT/live-bin/direnv"
  LIVE_REPO="$TEST_ROOT/live-source"
  LIVE_WT="$TEST_ROOT/app worktrees/live-random/live-service"
  git init -q -b main "$LIVE_REPO"
  git -C "$LIVE_REPO" config user.name Test
  git -C "$LIVE_REPO" config user.email test@example.invalid
  printf 'service/.env\n' >"$LIVE_REPO/.gitignore"
  printf 'dotenv service/.env\n' >"$LIVE_REPO/.envrc"
  git -C "$LIVE_REPO" add .gitignore .envrc
  git -C "$LIVE_REPO" commit -q -m synthetic-bootstrap
  mkdir -p "$(dirname "$LIVE_WT")"
  git -C "$LIVE_REPO" worktree add -q --detach "$LIVE_WT" main
  LIVE_WT=$(cd "$LIVE_WT" && pwd -P)
  printf 'PASSPORT_PATH_CHECK=synthetic-managed-value\n' >"$TEST_ROOT/live personal/service.env"
  cat >"$TEST_ROOT/live personal/projects.toml" <<'EOF'
[projects.live-service.environments.local.bootstrap]
env_links = [
  { source = "service.env", target = "service/.env" }
]
EOF
  live_run() {
    (
      export PATH="$TEST_ROOT/live-bin:$PATH"
      export XDG_CONFIG_HOME="$TEST_ROOT/live-config"
      export XDG_DATA_HOME="$TEST_ROOT/live-data"
      export DIRENV_CONFIG="$TEST_ROOT/live-config"
      export WORKTREE_PASSPORT_CONFIG="$TEST_ROOT/live personal/projects.toml"
      unset PASSPORT_PATH_CHECK
      cd "$LIVE_WT" && "$@"
    )
  }
  out=$(live_run "$PASSPORT" apply --project live-service --environment local --owner codex --expected-branch codex/live-path-check --new-branch --yes 2>&1); rc=$?
  [ "$rc" -eq 0 ] && contains "$out" 'direnv state: allowed' && [ "$LIVE_WT/service/.env" -ef "$TEST_ROOT/live personal/service.env" ] && ok 'real direnv allows managed envrc after the link is prepared' || { printf '%s\n' "$out"; not_ok 'real direnv allows managed envrc after the link is prepared'; }
  out=$(live_run "$REAL_DIRENV" exec "$LIVE_WT" /bin/bash -c 'test "$PASSPORT_PATH_CHECK" = synthetic-managed-value' 2>&1); rc=$?
  [ "$rc" -eq 0 ] && not_contains "$out" 'synthetic-managed-value' && ok 'real direnv loads the intended personal env value without printing it' || { printf '%s\n' "$out"; not_ok 'real direnv loads the intended personal env value without printing it'; }
  out=$(live_run "$REAL_DIRENV" exec "$LIVE_WT/service" /bin/bash -c 'test "$PASSPORT_PATH_CHECK" = synthetic-managed-value' 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok 'real env loading remains correct from a nested managed directory' || not_ok 'real env loading remains correct from a nested managed directory'
else
  printf '# live direnv loading checks skipped (direnv not installed)\n'
fi

printf '1..%d\n' "$((PASS + FAIL))"
printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
