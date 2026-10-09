#!/usr/bin/env bash

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PASSPORT=$(cd "$SCRIPT_DIR/../scripts" && pwd -P)/passport.sh
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worktree-passport-test.XXXXXX")
PASS=0
FAIL=0

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
  allow) : >"${MOCK_LOG}.direnv-allowed" ;;
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

REMOTE="$TEST_ROOT/origin.git"
git init --bare -q --initial-branch=main "$REMOTE"

REPO="$TEST_ROOT/example-service"
git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" remote add origin "$REMOTE"
printf 'service/.env\n' >"$REPO/.gitignore"
printf 'base\n' >"$REPO/tracked.txt"
git -C "$REPO" add .gitignore tracked.txt
git -C "$REPO" commit -q -m init

cat >"$WORKTREE_PASSPORT_CONFIG" <<EOF
[projects.example-service]
remote = "$REMOTE"

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
git -C "$REPO" push -q -u origin main

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
UPSTREAM="$TEST_ROOT/upstream"
git clone -q "$REMOTE" "$UPSTREAM"
git -C "$UPSTREAM" config user.name Upstream
git -C "$UPSTREAM" config user.email upstream@example.invalid
printf 'upstream\n' >>"$UPSTREAM/tracked.txt"
git -C "$UPSTREAM" add tracked.txt
git -C "$UPSTREAM" commit -q -m upstream
git -C "$UPSTREAM" push -q origin main
main_before=$(git -C "$REPO" rev-parse HEAD)
remote_head=$(git --git-dir="$REMOTE" rev-parse main)
out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-2 --expected-branch codex/TASK-2-feature --create --worktree "$NEW_WT" --base main 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$NEW_WT" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$main_before" ] && contains "$out" 'pull --ff-only origin main' && contains "$out" 'git worktree add' && ok 'main-based worktree preview includes pull without changing main' || not_ok 'main-based worktree preview includes pull without changing main'

out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-2 --expected-branch codex/TASK-2-feature --create --worktree "$NEW_WT" --base main --yes 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -d "$NEW_WT" ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$remote_head" ] && [ "$(git -C "$NEW_WT" rev-parse HEAD)" = "$remote_head" ] && [ "$(git -C "$NEW_WT" branch --show-current)" = codex/TASK-2-feature ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.project)" = example-service ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.environment)" = development ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.ticket)" = TASK-2 ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.owner)" = codex ] && [ "$(git -C "$NEW_WT" config --worktree --get passport.expected-branch)" = codex/TASK-2-feature ] && ok 'approved create updates main and branches from verified origin commit' || { printf '%s\n' "$out"; not_ok 'approved create updates main and branches from verified origin commit'; }

DIRTY_WT="$TEST_ROOT/example-service-TASK-7-feature"
printf 'dirty\n' >>"$REPO/tracked.txt"
out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-7 --expected-branch codex/TASK-7-feature --create --worktree "$DIRTY_WT" --base main 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$DIRTY_WT" ] && contains "$out" 'primary main worktree is dirty' && contains "$out" 'no pull attempted' && ok 'dirty primary main blocks pull and worktree creation' || not_ok 'dirty primary main blocks pull and worktree creation'
git -C "$REPO" restore tracked.txt

git -C "$REPO" branch release
RELEASE_WT="$TEST_ROOT/example-service-TASK-8-feature"
out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-8 --expected-branch codex/TASK-8-feature --create --worktree "$RELEASE_WT" --base release 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$RELEASE_WT" ] && not_contains "$out" 'pull --ff-only' && contains "$out" 'git worktree add' && ok 'non-main base is never synchronized automatically' || not_ok 'non-main base is never synchronized automatically'

printf 'local-only\n' >"$REPO/local-only.txt"
git -C "$REPO" add local-only.txt
git -C "$REPO" commit -q -m local-only
printf 'remote-only\n' >"$UPSTREAM/remote-only.txt"
git -C "$UPSTREAM" add remote-only.txt
git -C "$UPSTREAM" commit -q -m remote-only
git -C "$UPSTREAM" push -q origin main
DIVERGED_WT="$TEST_ROOT/example-service-TASK-9-feature"
out=$(run_in_repo apply --project example-service --environment development --owner codex --ticket TASK-9 --expected-branch codex/TASK-9-feature --create --worktree "$DIVERGED_WT" --base main --yes 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$DIVERGED_WT" ] && ! git -C "$REPO" show-ref --verify --quiet refs/heads/codex/TASK-9-feature && contains "$out" 'fast-forward pull from origin/main failed' && ok 'diverged main fails before branch and worktree creation' || { printf '%s\n' "$out"; not_ok 'diverged main fails before branch and worktree creation'; }

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

printf '1..%d\n' "$((PASS + FAIL))"
printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
