#!/usr/bin/env bash

set -u

PROGRAM=${0##*/}
MIN_SHARED_MISE_VERSION=2026.7.5
CONFIG_FILE=${WORKTREE_PASSPORT_CONFIG:-${CODEX_HOME:-$HOME/.codex}/worktree-passport/projects.toml}

say() { printf '%s\n' "$*"; }
err() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
die() { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

print_cmd() {
  printf '  '
  printf '%q ' "$@"
  printf '\n'
}

require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'not inside a Git worktree'
}

repo_root() {
  git rev-parse --show-toplevel
}

common_dir() {
  git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || {
    local raw parent
    raw=$(git rev-parse --git-common-dir) || return 1
    case "$raw" in
      /*) printf '%s\n' "$raw" ;;
      *) parent=$(repo_root) && (cd "$parent" && cd "$(dirname "$raw")" && printf '%s/%s\n' "$PWD" "$(basename "$raw")") ;;
    esac
  }
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'DETACHED@%s\n' "$(git rev-parse --short HEAD)"
}

remote_url() {
  local value first
  value=$(git config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return
  fi
  first=$(git remote 2>/dev/null | sed -n '1p')
  [ -n "$first" ] && git config --get "remote.$first.url" 2>/dev/null || true
}

worktree_config_enabled() {
  [ "$(git config --bool --get extensions.worktreeConfig 2>/dev/null || true)" = true ]
}

passport_get_at() {
  local target=$1 key=$2
  if git -C "$target" config --bool --get extensions.worktreeConfig 2>/dev/null | grep -q '^true$'; then
    git -C "$target" config --worktree --get "passport.$key" 2>/dev/null || true
  fi
}

toml_get() {
  local section=$1 key=$2
  [ -f "$CONFIG_FILE" ] || return 0
  awk -v wanted="[$section]" -v wanted_key="$key" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*\[/ {
      header=$0; sub(/[[:space:]]*#.*/, "", header); header=trim(header)
      active=(header == wanted); next
    }
    active {
      line=$0
      if (line ~ "^[[:space:]]*" wanted_key "[[:space:]]*=") {
        sub("^[[:space:]]*" wanted_key "[[:space:]]*=[[:space:]]*", "", line)
        line=trim(line)
        if (line ~ /^\"/) { sub(/^\"/, "", line); sub(/\"[[:space:]]*(#.*)?$/, "", line) }
        print line; exit
      }
    }
  ' "$CONFIG_FILE"
}

toml_env_links() {
  local section=$1
  [ -f "$CONFIG_FILE" ] || return 0
  awk -v wanted="[$section]" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*\[/ {
      header=$0; sub(/[[:space:]]*#.*/, "", header); header=trim(header)
      active=(header == wanted); next
    }
    active && /source[[:space:]]*=/ && /target[[:space:]]*=/ { print }
  ' "$CONFIG_FILE" | sed -n 's/.*source[[:space:]]*=[[:space:]]*"\([^"]*\)".*target[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1\	\2/p'
}

expand_personal_path() {
  case "$1" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(dirname "$CONFIG_FILE")" "$1" ;;
  esac
}

version_ge() {
  local left=$1 right=$2 l1 l2 l3 r1 r2 r3
  left=${left#v}; right=${right#v}
  left=${left%%[^0-9.]*}; right=${right%%[^0-9.]*}
  IFS=. read -r l1 l2 l3 <<EOF
$left
EOF
  IFS=. read -r r1 r2 r3 <<EOF
$right
EOF
  l1=${l1:-0}; l2=${l2:-0}; l3=${l3:-0}
  r1=${r1:-0}; r2=${r2:-0}; r3=${r3:-0}
  [ "$l1" -gt "$r1" ] || { [ "$l1" -eq "$r1" ] && { [ "$l2" -gt "$r2" ] || { [ "$l2" -eq "$r2" ] && [ "$l3" -ge "$r3" ]; }; }; }
}

detect_mise_config() {
  local root=$1 candidate
  for candidate in .mise.toml mise.toml .tool-versions; do
    [ -f "$root/$candidate" ] && { printf '%s\n' "$root/$candidate"; return; }
  done
}

mise_state() {
  local config=$1 output
  have mise || { printf 'not installed\n'; return; }
  output=$(mise trust --show "$config" 2>&1 || true)
  if printf '%s\n' "$output" | grep -F "$config" >/dev/null 2>&1; then
    printf 'trusted\n'
  elif printf '%s\n' "$output" | grep -Ei 'no trusted|untrusted|not trusted' >/dev/null 2>&1; then
    printf 'untrusted\n'
  else
    printf 'unknown\n'
  fi
}

direnv_state() {
  local root=$1 output
  have direnv || { printf 'not installed\n'; return; }
  output=$(cd "$root" && direnv status 2>&1 || true)
  if printf '%s\n' "$output" | grep -Eq '^Found RC allowed (0|true)$'; then
    printf 'allowed\n'
  else
    printf 'blocked\n'
  fi
}

path_within_worktree() {
  case "$1" in
    ''|/*|../*|*/../*|*/..|..|*'/../'*) return 1 ;;
    *) return 0 ;;
  esac
}

bootstrap_section() {
  printf 'projects.%s.environments.%s.bootstrap\n' "$1" "$2"
}

show_bootstrap_status() {
  local root=$1 project=$2 environment=$3 section config state version support rc rc_path hash source target expanded
  say 'Local workspace bootstrap:'

  config=$(detect_mise_config "$root")
  if [ -z "$config" ]; then
    say '  mise: not applicable (no config)'
  elif ! have mise; then
    say "  mise config: $config"
    say '  mise: not installed'
  else
    version=$(mise --version 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9.]*\).*/\1/p' | sed -n '1p')
    state=$(mise_state "$config")
    if version_ge "${version:-0}" "$MIN_SHARED_MISE_VERSION"; then support=supported; else support=unsupported; fi
    say "  mise version: ${version:-unknown}"
    say "  mise worktree trust sharing: $support (minimum $MIN_SHARED_MISE_VERSION)"
    say "  mise config: $config"
    say "  mise trust: $state"
  fi

  section=$(bootstrap_section "$project" "$environment")
  rc=$(toml_get "$section" direnv_rc)
  [ -n "$rc" ] || { [ -f "$root/.envrc" ] && rc=.envrc; }
  if [ -n "$rc" ]; then
    if ! path_within_worktree "$rc" || [ ! -f "$root/$rc" ]; then
      say "  direnv: invalid or missing rc ($rc)"
    else
      state=$(direnv_state "$root")
      hash=$(git -C "$root" hash-object -- "$rc" 2>/dev/null || true)
      say "  direnv rc: $root/$rc"
      say "  direnv hash: ${hash:-unknown}"
      say "  direnv state: $state"
    fi
  else
    say '  direnv: not applicable (no rc)'
  fi

  if [ -n "$project" ] && [ -n "$environment" ]; then
    while IFS="$(printf '\t')" read -r source target; do
      [ -n "$source" ] || continue
      expanded=$(expand_personal_path "$source")
      if [ -L "$root/$target" ] && [ "$(readlink "$root/$target")" = "$expanded" ]; then state=linked
      elif [ -e "$root/$target" ] || [ -L "$root/$target" ]; then state='occupied (not changed)'
      elif [ ! -f "$expanded" ]; then state='source missing'
      elif ! git -C "$root" check-ignore -q -- "$target"; then state='target not ignored'
      else state='ready to link'
      fi
      say "  env link: $expanded -> $root/$target [$state]"
    done <<EOF
$(toml_env_links "$section")
EOF
  fi
}

validate_runtime() {
  local root=$1 project=$2 environment=$3 remote section configured_remote aws_profile aws_account aws_region eks_cluster kube_context namespace actual_account found_context
  [ -n "$project" ] || { err 'runtime target verification failed: passport.project is missing'; return 1; }
  [ -n "$environment" ] || { err 'runtime target verification failed: passport.environment is missing'; return 1; }
  [ -f "$CONFIG_FILE" ] || { err "runtime target verification failed: config not found: $CONFIG_FILE"; return 1; }

  configured_remote=$(toml_get "projects.$project" remote)
  remote=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$configured_remote" ] || { err "runtime target verification failed: project '$project' is not configured"; return 1; }
  [ "$remote" = "$configured_remote" ] || { err "runtime target verification failed: remote does not match project '$project'"; return 1; }

  section="projects.$project.environments.$environment"
  aws_profile=$(toml_get "$section" aws_profile)
  aws_account=$(toml_get "$section" aws_account_id)
  aws_region=$(toml_get "$section" aws_region)
  eks_cluster=$(toml_get "$section" eks_cluster)
  kube_context=$(toml_get "$section" kube_context)
  namespace=$(toml_get "$section" namespace)
  [ -n "$aws_profile" ] && [ -n "$aws_account" ] && [ -n "$aws_region" ] || { err "runtime target verification failed: incomplete AWS target for $project/$environment"; return 1; }
  [ -n "$eks_cluster" ] && [ -n "$kube_context" ] && [ -n "$namespace" ] || { err "runtime target verification failed: incomplete Kubernetes target for $project/$environment"; return 1; }

  say 'Runtime target (expected):'
  say "  AWS profile: $aws_profile"
  say "  AWS account: $aws_account"
  say "  AWS region: $aws_region"
  say "  EKS cluster: $eks_cluster"
  say "  kube context: $kube_context"
  say "  namespace: $namespace"

  have aws || { err 'runtime target verification failed: aws CLI is not installed'; return 1; }
  if ! aws configure list-profiles 2>/dev/null | grep -Fx "$aws_profile" >/dev/null 2>&1; then
    err "runtime target verification failed: expected AWS profile '$aws_profile' is unavailable; no fallback attempted"
    return 1
  fi
  actual_account=$(aws --profile "$aws_profile" --region "$aws_region" sts get-caller-identity --query Account --output text 2>/dev/null) || {
    err "runtime target verification failed: caller identity failed for profile '$aws_profile'; no fallback attempted"
    return 1
  }
  [ "$actual_account" = "$aws_account" ] || {
    err "runtime target verification failed: AWS account mismatch (expected $aws_account, actual $actual_account); no fallback attempted"
    return 1
  }
  say "  AWS caller account: $actual_account [match]"

  have kubectl || { err 'runtime target verification failed: kubectl is not installed'; return 1; }
  found_context=$(kubectl --context "$kube_context" --namespace "$namespace" config get-contexts "$kube_context" -o name 2>/dev/null || true)
  [ "$found_context" = "$kube_context" ] || {
    err "runtime target verification failed: expected kube context '$kube_context' is unavailable; current context was not used"
    return 1
  }
  say '  kube context exists: yes'
  if ! kubectl --context "$kube_context" --namespace "$namespace" get namespace "$namespace" -o name >/dev/null 2>&1; then
    err "runtime target verification failed: namespace '$namespace' is missing or inaccessible in the expected context; no fallback attempted"
    return 1
  fi
  say '  namespace access: verified'
}

validate_linear_target() {
  local root=$1 project=$2 ticket=$3 live=$4 section configured_remote remote workspace_id team_id team_key project_id project_name actual_workspace actual_team actual_project rc=0
  if [ -z "$project" ]; then
    say 'Linear target: not configured'
    if $live; then
      err 'external target verification failed: passport.project is missing'
      return 1
    fi
    return 0
  fi

  section="projects.$project.targets.linear"
  workspace_id=$(toml_get "$section" workspace_id)
  team_id=$(toml_get "$section" team_id)
  team_key=$(toml_get "$section" team_key)
  project_id=$(toml_get "$section" project_id)
  project_name=$(toml_get "$section" project_name)

  if [ -z "$workspace_id$team_id$team_key$project_id$project_name" ]; then
    say 'Linear target: not configured'
    if $live; then
      err "external target verification failed: Linear target is not configured for project '$project'"
      return 1
    fi
    return 0
  fi

  say 'Linear target (expected):'
  say "  workspace ID: ${workspace_id:-not configured}"
  say "  team ID: ${team_id:-not configured}"
  say "  team key: ${team_key:-not configured}"
  say "  project ID: ${project_id:-not configured}"
  say "  project name: ${project_name:-not configured}"

  if [ -z "$workspace_id" ] || [ -z "$team_id" ] || [ -z "$team_key" ] || [ -z "$project_id" ] || [ -z "$project_name" ]; then
    err "external target verification failed: incomplete Linear target for project '$project'"
    return 1
  fi

  if [ -n "$ticket" ]; then
    case "$ticket" in
      "$team_key"-*) say '  ticket team match: yes' ;;
      *)
        say '  ticket team match: no'
        err "external target verification failed: ticket '$ticket' does not belong to Linear team '$team_key'"
        rc=1
        ;;
    esac
  else
    say '  ticket team match: not configured'
    if $live; then
      err 'external target verification failed: passport.ticket is required for Linear operations'
      rc=1
    fi
  fi

  if $live; then
    configured_remote=$(toml_get "projects.$project" remote)
    remote=$(git -C "$root" config --get remote.origin.url 2>/dev/null || true)
    if [ -z "$configured_remote" ] || [ "$remote" != "$configured_remote" ]; then
      err "external target verification failed: Git remote does not match project '$project'"
      rc=1
    fi

    actual_workspace=${WORKTREE_PASSPORT_LINEAR_WORKSPACE_ID:-}
    actual_team=${WORKTREE_PASSPORT_LINEAR_TEAM_ID:-}
    actual_project=${WORKTREE_PASSPORT_LINEAR_PROJECT_ID:-}
    if [ -z "$actual_workspace" ] || [ -z "$actual_team" ] || [ -z "$actual_project" ]; then
      err 'external target verification failed: live Linear workspace/team/project IDs were not supplied; no fallback attempted'
      rc=1
    else
      [ "$actual_workspace" = "$workspace_id" ] || { err 'external target verification failed: Linear workspace mismatch; no fallback attempted'; rc=1; }
      [ "$actual_team" = "$team_id" ] || { err 'external target verification failed: Linear team mismatch; no fallback attempted'; rc=1; }
      [ "$actual_project" = "$project_id" ] || { err 'external target verification failed: Linear project mismatch; no fallback attempted'; rc=1; }
      [ "$rc" -ne 0 ] || say '  live Linear identity: verified'
    fi
  fi
  return "$rc"
}

status_command() {
  local runtime=false external=false root branch common remote enabled project environment ticket owner expected rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime) runtime=true ;;
      --external) external=true ;;
      *) die 'usage: passport.sh status [--runtime] [--external]' ;;
    esac
    shift
  done
  require_repo
  root=$(repo_root); common=$(common_dir); branch=$(current_branch); remote=$(remote_url)
  if worktree_config_enabled; then enabled=true; else enabled=false; fi
  project=$(passport_get_at "$root" project)
  environment=$(passport_get_at "$root" environment)
  ticket=$(passport_get_at "$root" ticket)
  owner=$(passport_get_at "$root" owner)
  expected=$(passport_get_at "$root" expected-branch)

  say "Repository root: $root"
  say "Git common directory: $common"
  say "Worktree path: $root"
  say "Current branch: $branch"
  say "Remote URL: ${remote:-not configured}"
  say "extensions.worktreeConfig: $enabled"
  if [ -z "$project$environment$ticket$owner$expected" ]; then
    say 'Passport: not configured'
  else
    say 'Passport:'
    say "  project: ${project:-not configured}"
    say "  environment: ${environment:-not configured}"
    say "  ticket: ${ticket:-not configured}"
    say "  owner: ${owner:-not configured}"
    say "  expected branch: ${expected:-not configured}"
  fi
  if [ -n "$expected" ]; then
    if [ "$expected" = "$branch" ]; then say 'Expected branch match: yes'
    else say 'Expected branch match: no'; rc=1
    fi
  else
    say 'Expected branch match: not configured'
  fi
  validate_linear_target "$root" "$project" "$ticket" "$external" || rc=1
  show_bootstrap_status "$root" "$project" "$environment"
  if $runtime; then validate_runtime "$root" "$project" "$environment" || rc=1; fi
  return "$rc"
}

primary_worktree() {
  git worktree list --porcelain | awk '/^worktree / { sub(/^worktree /, ""); print; exit }'
}

validate_main_base_sync() {
  local primary=$1 branch origin dirty
  branch=$(git -C "$primary" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = main ] || {
    err "main synchronization failed: primary worktree is on '${branch:-detached}', not 'main'"
    return 1
  }
  dirty=$(git -C "$primary" status --porcelain --untracked-files=normal 2>/dev/null) || {
    err 'main synchronization failed: primary worktree status could not be read'
    return 1
  }
  [ -z "$dirty" ] || {
    err 'main synchronization failed: primary main worktree is dirty; no pull attempted'
    return 1
  }
  origin=$(git -C "$primary" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$origin" ] || {
    err "main synchronization failed: remote 'origin' is not configured"
    return 1
  }
}

sync_main_base() {
  local primary=$1 head fetched
  validate_main_base_sync "$primary" || return 1
  git -C "$primary" pull --ff-only origin main || {
    err 'main synchronization failed: fast-forward pull from origin/main failed; worktree was not created'
    return 1
  }
  head=$(git -C "$primary" rev-parse HEAD 2>/dev/null) || return 1
  fetched=$(git -C "$primary" rev-parse FETCH_HEAD 2>/dev/null) || {
    err 'main synchronization failed: fetched origin/main commit could not be verified'
    return 1
  }
  [ "$head" = "$fetched" ] || {
    err 'main synchronization failed: local main is not identical to origin/main after pull; worktree was not created'
    return 1
  }
  say 'Primary main synchronized with origin/main (fast-forward only).'
}

absolute_new_path() {
  local raw=$1 parent base
  case "$raw" in
    /*) parent=$(dirname "$raw"); base=$(basename "$raw") ;;
    *) parent=$PWD/$(dirname "$raw"); base=$(basename "$raw") ;;
  esac
  [ -d "$parent" ] || return 1
  parent=$(cd "$parent" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$base"
}

plan_bootstrap() {
  local source_root=$1 target_root=$2 project=$3 environment=$4 section config version state rc source target expanded any=false
  section=$(bootstrap_section "$project" "$environment")
  say 'Local workspace bootstrap:'
  config=$(detect_mise_config "$source_root")
  if [ -n "$config" ]; then
    config="$target_root/${config#$source_root/}"
    if have mise; then
      version=$(mise --version 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9.]*\).*/\1/p' | sed -n '1p')
      say "  mise version: ${version:-unknown}"
      if version_ge "${version:-0}" "$MIN_SHARED_MISE_VERSION"; then say '  worktree trust sharing: supported'
      else say "  worktree trust sharing: unsupported (upgrade is separate; minimum $MIN_SHARED_MISE_VERSION)"; fi
      if [ -d "$target_root" ]; then state=$(mise_state "$config"); else state='verify after creation'; fi
      say "  config: $config"
      say "  trust: $state"
      if [ "$state" != trusted ]; then say "  planned change: mise trust $config"; any=true; fi
    else
      say "  mise config: $config"
      say '  blocked: mise is not installed (installation is not included)'
      return 1
    fi
  else
    say '  mise: not applicable'
  fi

  rc=$(toml_get "$section" direnv_rc)
  [ -n "$rc" ] || { [ -f "$source_root/.envrc" ] && rc=.envrc; }
  if [ -n "$rc" ]; then
    path_within_worktree "$rc" || { err "invalid direnv_rc path: $rc"; return 1; }
    [ -f "$source_root/$rc" ] || { err "configured direnv rc does not exist: $source_root/$rc"; return 1; }
    if ! have direnv; then err 'direnv rc exists but direnv is not installed'; return 1; fi
    if [ -d "$target_root" ]; then state=$(direnv_state "$target_root"); else state='verify after creation'; fi
    say "  direnv rc: $target_root/$rc"
    say "  direnv hash: $(git -C "$source_root" hash-object -- "$rc")"
    say "  direnv state: $state"
    if [ "$state" != allowed ]; then say "  planned change: direnv allow $target_root"; any=true; fi
  else
    say '  direnv: not applicable'
  fi

  while IFS="$(printf '\t')" read -r source target; do
    [ -n "$source" ] || continue
    path_within_worktree "$target" || { err "invalid env target path: $target"; return 1; }
    expanded=$(expand_personal_path "$source")
    [ -f "$expanded" ] || { err "env source is missing: $expanded"; return 1; }
    if [ -e "$target_root/$target" ] || [ -L "$target_root/$target" ]; then
      if [ -L "$target_root/$target" ] && [ "$(readlink "$target_root/$target")" = "$expanded" ]; then
        say "  env link already correct: $expanded -> $target_root/$target"
        continue
      fi
      err "env target already exists and will not be overwritten: $target_root/$target"
      return 1
    fi
    git -C "$source_root" check-ignore -q -- "$target" || { err "env target is not Git-ignored: $target"; return 1; }
    say "  planned link: $expanded -> $target_root/$target"
    any=true
  done <<EOF
$(toml_env_links "$section")
EOF
  $any || say '  planned changes: none'
  say '  project tracked files changed: no'
  say '  env contents displayed: no'
}

apply_bootstrap() {
  local root=$1 project=$2 environment=$3 section config state rc source target expanded
  section=$(bootstrap_section "$project" "$environment")
  config=$(detect_mise_config "$root")
  if [ -n "$config" ]; then
    state=$(mise_state "$config")
    if [ "$state" != trusted ]; then
      mise trust "$config" || { err "mise trust failed: $config"; return 1; }
    fi
  fi
  rc=$(toml_get "$section" direnv_rc)
  [ -n "$rc" ] || { [ -f "$root/.envrc" ] && rc=.envrc; }
  if [ -n "$rc" ]; then
    state=$(direnv_state "$root")
    if [ "$state" != allowed ]; then
      direnv allow "$root" || { err "direnv allow failed: $root"; return 1; }
      state=$(direnv_state "$root")
      [ "$state" = allowed ] || { err "direnv verification failed after allow: $root"; return 1; }
    fi
  fi
  while IFS="$(printf '\t')" read -r source target; do
    [ -n "$source" ] || continue
    expanded=$(expand_personal_path "$source")
    if [ -L "$root/$target" ] && [ "$(readlink "$root/$target")" = "$expanded" ]; then continue; fi
    [ -f "$expanded" ] || { err "env source disappeared before apply: $expanded"; return 1; }
    path_within_worktree "$target" || { err "invalid env target path: $target"; return 1; }
    if [ -e "$root/$target" ] || [ -L "$root/$target" ]; then
      err "env target appeared before apply and will not be overwritten: $root/$target"
      return 1
    fi
    git -C "$root" check-ignore -q -- "$target" || { err "env target is not Git-ignored: $target"; return 1; }
    mkdir -p "$(dirname "$root/$target")" || return 1
    ln -s "$expanded" "$root/$target" || { err "failed to create env link: $root/$target"; return 1; }
  done <<EOF
$(toml_env_links "$section")
EOF
}

apply_command() {
  local project= environment= ticket= owner= expected= worktree= base= create=false yes=false root target source_root primary parent expected_parent branch enabled
  while [ $# -gt 0 ]; do
    case "$1" in
      --project|--environment|--ticket|--owner|--expected-branch|--worktree|--base)
        [ $# -ge 2 ] || die "missing value for $1"
        case "$1" in
          --project) project=$2 ;; --environment) environment=$2 ;; --ticket) ticket=$2 ;;
          --owner) owner=$2 ;; --expected-branch) expected=$2 ;; --worktree) worktree=$2 ;; --base) base=$2 ;;
        esac
        shift 2 ;;
      --create) create=true; shift ;;
      --yes) yes=true; shift ;;
      *) die "unknown apply option: $1" ;;
    esac
  done
  [ -n "$project" ] || die '--project is required'
  [ -n "$environment" ] || die '--environment is required'
  [ -n "$owner" ] || die '--owner is required'
  [ -n "$expected" ] || die '--expected-branch is required'
  require_repo
  root=$(repo_root); source_root=$root; target=$root; branch=$(current_branch)
  if $create; then
    [ -n "$worktree" ] && [ -n "$base" ] || die '--create requires --worktree and --base'
    target=$(absolute_new_path "$worktree") || die 'worktree parent directory does not exist'
    primary=$(primary_worktree); primary=$(cd "$primary" && pwd -P)
    parent=$(dirname "$target"); expected_parent=$(dirname "$primary")
    [ "$parent" = "$expected_parent" ] || die "new worktree must be a sibling of the primary repository: $expected_parent"
    [ ! -e "$target" ] && [ ! -L "$target" ] || die "worktree path already exists: $target"
    git show-ref --verify --quiet "refs/heads/$expected" && die "branch already exists: $expected"
    git rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || die "base does not resolve to a commit: $base"
    if [ "$base" = main ]; then
      validate_main_base_sync "$primary" || die 'main synchronization preflight failed; nothing was changed'
    fi
  else
    [ -z "$worktree" ] || die '--worktree requires --create'
    [ -z "$base" ] || die '--base requires --create'
    [ "$branch" = "$expected" ] || die "expected branch '$expected' does not match current branch '$branch'"
  fi
  if [ -n "$ticket" ]; then
    case "$expected" in *"$ticket"*) ;; *) die "ticket '$ticket' must appear in branch '$expected'" ;; esac
    if $create; then case "$(basename "$target")" in *"$ticket"*) ;; *) die "ticket '$ticket' must appear in worktree directory name" ;; esac; fi
  fi
  validate_linear_target "$source_root" "$project" "$ticket" false || die 'Linear target validation failed; nothing was changed'

  say 'Worktree Passport plan:'
  say "  repository: $root"
  say "  base branch: ${base:-not applicable}"
  say "  target branch: $expected"
  say "  worktree path: $target"
  say "  ticket: ${ticket:-not configured}"
  say "  owner: $owner"
  say "  project: $project"
  say "  environment: $environment"
  if [ -f "$CONFIG_FILE" ]; then
    say '  expected runtime target:'
    say "    AWS profile: $(toml_get "projects.$project.environments.$environment" aws_profile)"
    say "    AWS account: $(toml_get "projects.$project.environments.$environment" aws_account_id)"
    say "    AWS region: $(toml_get "projects.$project.environments.$environment" aws_region)"
    say "    EKS cluster: $(toml_get "projects.$project.environments.$environment" eks_cluster)"
    say "    kube context: $(toml_get "projects.$project.environments.$environment" kube_context)"
    say "    namespace: $(toml_get "projects.$project.environments.$environment" namespace)"
  else
    say "  expected runtime target: not configured ($CONFIG_FILE)"
  fi
  say '  runtime configuration changes: none (read-only verification only)'
  say '  Git changes:'
  worktree_config_enabled && enabled=true || enabled=false
  [ "$enabled" = true ] || print_cmd git config extensions.worktreeConfig true
  if $create && [ "$base" = main ]; then
    print_cmd git -C "$primary" pull --ff-only origin main
  fi
  $create && print_cmd git worktree add -b "$expected" "$target" "$base"
  print_cmd git -C "$target" config --worktree passport.project "$project"
  print_cmd git -C "$target" config --worktree passport.environment "$environment"
  [ -n "$ticket" ] && print_cmd git -C "$target" config --worktree passport.ticket "$ticket"
  print_cmd git -C "$target" config --worktree passport.owner "$owner"
  print_cmd git -C "$target" config --worktree passport.expected-branch "$expected"
  plan_bootstrap "$source_root" "$target" "$project" "$environment" || die 'bootstrap preflight failed; nothing was changed'
  say '  project file changes: none'
  say '  cloud changes or deployment: none'

  $yes || { say 'Dry run only. Re-run this exact plan with --yes after explicit approval.'; return 0; }

  if $create && [ "$base" = main ]; then
    sync_main_base "$primary" || die 'main synchronization stopped the apply before worktree creation'
  fi
  if [ "$enabled" != true ]; then git config extensions.worktreeConfig true || die 'failed to enable extensions.worktreeConfig'; fi
  if $create; then
    git worktree add -b "$expected" "$target" "$base" || die 'failed to create worktree; no Passport values were written'
  fi
  git -C "$target" config --worktree passport.project "$project" || die "Passport write failed; worktree preserved at $target"
  git -C "$target" config --worktree passport.environment "$environment" || die "Passport write failed; worktree preserved at $target"
  if [ -n "$ticket" ]; then git -C "$target" config --worktree passport.ticket "$ticket" || die "Passport write failed; worktree preserved at $target"
  else git -C "$target" config --worktree --unset-all passport.ticket >/dev/null 2>&1 || true; fi
  git -C "$target" config --worktree passport.owner "$owner" || die "Passport write failed; worktree preserved at $target"
  git -C "$target" config --worktree passport.expected-branch "$expected" || die "Passport write failed; worktree preserved at $target"
  apply_bootstrap "$target" "$project" "$environment" || die "Passport applied but bootstrap partially failed; worktree preserved at $target"
  say 'Applied. Verification:'
  (cd "$target" && "$0" status) || die 'apply completed but verification failed'
}

remove_command() {
  local yes=false root key existing any=false
  while [ $# -gt 0 ]; do case "$1" in --yes) yes=true ;; *) die "unknown remove option: $1" ;; esac; shift; done
  require_repo; root=$(repo_root)
  say 'Worktree Passport removal plan:'
  for key in project environment ticket owner expected-branch; do
    existing=$(passport_get_at "$root" "$key")
    if [ -n "$existing" ]; then say "  remove passport.$key (current: $existing)"; any=true; fi
  done
  $any || { say '  no Passport keys are configured'; return 0; }
  say '  preserved: worktree, branch, extensions.worktreeConfig, runtime config, bootstrap files'
  $yes || { say 'Dry run only. Re-run with --yes after explicit approval.'; return 0; }
  for key in project environment ticket owner expected-branch; do
    git config --worktree --unset-all "passport.$key" >/dev/null 2>&1 || true
  done
  say 'Passport keys removed. Worktree and branch were preserved.'
}

usage() {
  cat <<'EOF'
Usage:
  passport.sh status [--runtime] [--external]
  passport.sh apply --project NAME --environment NAME --owner NAME --expected-branch BRANCH [--ticket ID] [--create --worktree PATH --base BRANCH] [--yes]
  passport.sh remove [--yes]
EOF
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  local command=$1; shift
  case "$command" in
    status) status_command "$@" ;;
    apply) apply_command "$@" ;;
    remove) remove_command "$@" ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
}

main "$@"
