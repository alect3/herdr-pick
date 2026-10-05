#!/usr/bin/env bats
# Unit + integration tests for the herdr picker scripts.
#
#   bats test/
#
# CI runs these via .github/workflows/lint.yml. Three things are covered:
# the pure config-resolution helpers (parse_destination, clone_dest,
# resolve_default_owner), pick-repos-refresh's atomic keep-last-good
# behaviour (with `gh` stubbed), and the dispatch end-to-end with `herdr`,
# `fzf` and `gh` stubbed. The herdr server, the fzf UI and the real gh
# network calls are exercised by hand.

setup() {
  PICK="$BATS_TEST_DIRNAME/../herdr-pick/files/herdr-pick.sh"
  REFRESH="$BATS_TEST_DIRNAME/../herdr-pick/files/pick-repos-refresh.sh"
}

# Load the pure functions out of herdr-pick.sh without running its main
# body (discovery / fzf / dispatch). Relies on each being a top-level
# `name() { ... }` block with the closing brace in column 0. Call after
# setting HOME: the default PICK_SITES table is built here, from it.
load_pick_fns() {
  eval "$(awk '/^parse_destination\(\) \{/,/^\}/' "$PICK")"
  eval "$(awk '/^clone_dest\(\) \{/,/^\}/' "$PICK")"
  eval "$(awk '/^resolve_default_owner\(\) \{/,/^\}/' "$PICK")"
  PICK_SITES=("projects:$HOME/projects:")   # the no-config default table
}

# --- parse_destination --------------------------------------------------

@test "parse_destination: bare name → first site dir + default owner" {
  export HOME=/h
  load_pick_fns
  run parse_destination myapp alect3
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/projects/myapp\talect3')" ]
}

@test "parse_destination: bare name with empty default owner → local only" {
  export HOME=/h
  load_pick_fns
  run parse_destination myapp ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/projects/myapp\t-')" ]
}

@test "parse_destination: first site name also works as a prefix" {
  export HOME=/h
  load_pick_fns
  run parse_destination projects/myapp alect3
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/projects/myapp\talect3')" ]
}

@test "parse_destination: custom site table maps prefixes" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=(
    "projects:$HOME/projects:"
    "work:$HOME/work:acme"
    "r:$HOME/sandbox:-"
  )
  run parse_destination work/api acme
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/work/api\tacme')" ]
  run parse_destination r/scratch acme
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/sandbox/scratch\t-')" ]
}

@test "parse_destination: bare name falls to the first site" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("work:$HOME/work:acme" "r:$HOME/sandbox:-")
  run parse_destination myapp ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/work/myapp\tacme')" ]
}

@test "parse_destination: site owner '-' stays local even with a default owner" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("r:$HOME/sandbox:-")
  run parse_destination r/billing alect3
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/sandbox/billing\t-')" ]
}

@test "parse_destination: site with empty owner inherits the default owner" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("projects:$HOME/projects:")
  run parse_destination myapp alect3
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/projects/myapp\talect3')" ]
  run parse_destination myapp ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/projects/myapp\t-')" ]
}

@test "parse_destination: prefix is case-insensitive" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("work:$HOME/work:acme" "r:$HOME/sandbox:-")
  run parse_destination WORK/api acme
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/work/api\tacme')" ]
  run parse_destination R/billing acme
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/h/sandbox/billing\t-')" ]
}

@test "parse_destination: unknown prefix is rejected (typo guard)" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("projects:$HOME/projects:" "work:$HOME/work:acme")
  run parse_destination Wrk/billing acme
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run parse_destination foo/billing acme
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "parse_destination: empty leaf and multi-level paths rejected" {
  export HOME=/h
  load_pick_fns
  run parse_destination projects/ acme
  [ "$status" -ne 0 ]
  run parse_destination projects/a/b acme
  [ "$status" -ne 0 ]
}

@test "parse_destination: empty input rejected" {
  load_pick_fns
  run parse_destination "" acme
  [ "$status" -ne 0 ]
}

# --- clone_dest ---------------------------------------------------------

@test "clone_dest: explicit PICK_OWNER_DIR wins" {
  export HOME=/h
  load_pick_fns
  declare -A PICK_OWNER_DIR=()
  PICK_OWNER_DIR[acme]="$HOME/work"
  run clone_dest acme
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work" ]
}

@test "clone_dest: first site owned by the owner wins" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("projects:$HOME/projects:you" "work:$HOME/work:acme" "w:$HOME/work:acme")
  run clone_dest acme
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work" ]
  run clone_dest you
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/projects" ]
}

@test "clone_dest: unknown owner falls back to the first site's dir" {
  export HOME=/h
  load_pick_fns
  PICK_SITES=("projects:$HOME/projects:you" "r:$HOME/sandbox:-")
  run clone_dest stranger
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/projects" ]
}

# --- resolve_default_owner ----------------------------------------------

@test "resolve_default_owner: PICK_DEFAULT_OWNER wins without calling gh" {
  load_pick_fns
  PICK_DEFAULT_OWNER=you
  run resolve_default_owner
  [ "$status" -eq 0 ]
  [ "$output" = "you" ]
}

@test "resolve_default_owner: falls back to gh api user" {
  load_pick_fns
  stub_bin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho "cache-miss-user"\n' >"$stub_bin/gh"
  chmod +x "$stub_bin/gh"
  PATH="$stub_bin:/usr/bin:/bin"
  unset PICK_DEFAULT_OWNER
  run resolve_default_owner
  [ "$status" -eq 0 ]
  [ "$output" = "cache-miss-user" ]
}

# --- pick-repos-refresh: atomic keep-last-good ---------------------------

# Stub `gh` so the test never touches the network. The script invokes
# `gh repo list <owner> ...`, i.e. $1=repo $2=list $3=<owner>.
_stub_gh() { # $1 = body
  mkdir -p "$STUB_HOME/bin"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$1"; } >"$STUB_HOME/bin/gh"
  chmod +x "$STUB_HOME/bin/gh"
}

# Write a pick.conf for the refresh script (bash arrays cannot cross a
# process boundary, so the config-under-test always goes through a real
# conf file) and point HERDR_PICK_CONF at it.
refresh_setup() { # $1 = conf body (optional)
  STUB_HOME="$(mktemp -d)"
  export HOME="$STUB_HOME"
  export XDG_CACHE_HOME="$STUB_HOME/.cache"
  export HERDR_PICK_CONF="$STUB_HOME/pick.conf"
  : >"$HERDR_PICK_CONF"
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1" >"$HERDR_PICK_CONF"
  fi
}

@test "refresh: configured owners write the cache in precedence order" {
  refresh_setup 'PICK_OWNERS=(you acme)'
  _stub_gh 'owner="$3"; printf "%s/repo-a\n%s/repo-b\n" "$owner" "$owner"'
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
  run bash "$REFRESH"
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CACHE_HOME/pick/repos")" = "$(printf 'you/repo-a\nyou/repo-b\nacme/repo-a\nacme/repo-b')" ]
}

@test "refresh: no owners configured falls back to the gh user" {
  refresh_setup
  mkdir -p "$STUB_HOME/bin"
  cat >"$STUB_HOME/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$2" = "list" ]; then printf '%s/todo-cli\n' "$3"; else echo "cache-miss-user"; fi
STUB
  chmod +x "$STUB_HOME/bin/gh"
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
  run bash "$REFRESH"
  [ "$status" -eq 0 ]
  grep -qx 'cache-miss-user/todo-cli' "$XDG_CACHE_HOME/pick/repos"
}

@test "refresh: gh failure keeps the last-good cache" {
  refresh_setup 'PICK_OWNERS=(you)'
  mkdir -p "$XDG_CACHE_HOME/pick"
  printf 'you/preexisting\n' >"$XDG_CACHE_HOME/pick/repos"
  _stub_gh 'exit 3'
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
  run bash "$REFRESH"
  [ "$status" -ne 0 ]
  [ "$(cat "$XDG_CACHE_HOME/pick/repos")" = 'you/preexisting' ]
}

@test "refresh: empty listing keeps the last-good cache" {
  refresh_setup 'PICK_OWNERS=(you)'
  mkdir -p "$XDG_CACHE_HOME/pick"
  printf 'you/preexisting\n' >"$XDG_CACHE_HOME/pick/repos"
  _stub_gh 'exit 0'   # no output
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
  run bash "$REFRESH"
  [ "$status" -ne 0 ]
  [ "$(cat "$XDG_CACHE_HOME/pick/repos")" = 'you/preexisting' ]
}

@test "refresh: no owners and no gh user fails closed" {
  refresh_setup
  mkdir -p "$STUB_HOME/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_HOME/bin/gh"
  chmod +x "$STUB_HOME/bin/gh"
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
  run bash "$REFRESH"
  [ "$status" -ne 0 ]
}

# --- dispatch end-to-end (herdr / fzf / gh stubbed) ----------------------
#
# The whole picker runs with stubbed commands logging their arguments, so
# the dispatch contract is checked for real: fzf's output drives herdr's
# workspace/pane CLI. jq stays REAL, parsing the stub responses, a jq-side
# API-shape regression in open_project fails the test instead of hiding.
#
# fzf stub: the first call (the menu, --print-query) prints $1 verbatim;
# later calls (the create confirm) print a line chosen from stdin by
# $FZF_LATER_PICK ("first" = Cancel, anything else = the Create line).

dispatch_setup() { # $1 = first fzf call output
  STUB_HOME="$(mktemp -d)"
  export HOME="$STUB_HOME"
  export XDG_CACHE_HOME="$STUB_HOME/.cache"
  export HERDR_LOG="$STUB_HOME/herdr.log"
  export GH_LOG="$STUB_HOME/gh.log"
  export PICK_DEFAULT_OWNER=you   # keep gh api out of the create path
  export HERDR_PICK_CONF=/nonexistent
  export FZF_STATE="$STUB_HOME/fzf.calls"
  : >"$FZF_STATE"
  FZF_FIRST="$1"
  export FZF_FIRST
  export FZF_LATER_PICK="${FZF_LATER_PICK:-last}"
  mkdir -p "$STUB_HOME/bin" "$STUB_HOME/projects"

  cat >"$STUB_HOME/bin/herdr" <<'STUB'
#!/usr/bin/env bash
echo "herdr $*" >>"$HERDR_LOG"
case "$1 $2" in
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"dotfiles"}]}}' ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"p1"}}}' ;;
  "pane split") echo '{"result":{"pane":{"pane_id":"p2"}}}' ;;
  *) echo '{}' ;;
esac
STUB

  cat >"$STUB_HOME/bin/fzf" <<'STUB'
#!/usr/bin/env bash
# Always consume stdin first: the picker pipes the menu in under
# pipefail, and a stub exiting without reading would SIGPIPE the writer
# (the real fzf always drains its input too).
input="$(cat)"
n="$(cat "$FZF_STATE")"
n="${n:-0}"
echo $((n + 1)) >"$FZF_STATE"
if [ "$n" -eq 0 ]; then
  printf '%s\n' "$FZF_FIRST"
elif [ "$FZF_LATER_PICK" = "first" ]; then
  sed -n 1p <<<"$input"
else
  grep . <<<"$input" | tail -n 1
fi
STUB

  printf '#!/usr/bin/env bash\necho "gh $*" >>"%s"\n' "$GH_LOG" >"$STUB_HOME/bin/gh"
  chmod +x "$STUB_HOME/bin/"*
  export PATH="$STUB_HOME/bin:/usr/bin:/bin"
}

@test "dispatch: selecting an open workspace focuses it" {
  dispatch_setup $'dotfiles\n● dotfiles'
  run bash "$PICK"
  [ "$status" -eq 0 ]
  grep -Fx 'herdr workspace focus w1' "$HERDR_LOG"
  ! grep -q 'workspace create' "$HERDR_LOG"
}

@test "dispatch: selecting a local project opens a labelled workspace" {
  dispatch_setup $'notes-api\nnotes-api'
  mkdir -p "$HOME/projects/notes-api"
  run bash "$PICK"
  [ "$status" -eq 0 ]
  grep -Fx "herdr workspace create --cwd $HOME/projects/notes-api --label notes-api --focus" "$HERDR_LOG"
  grep -F 'herdr pane split p1 --direction right' "$HERDR_LOG"
  grep -F 'herdr pane focus --direction left --pane p2' "$HERDR_LOG"
}

@test "dispatch: selecting a cached repo clones it then opens it" {
  dispatch_setup $'feedbox\n↓ feedbox'
  mkdir -p "$XDG_CACHE_HOME/pick"
  printf 'you/feedbox\nacme/feature-flags\n' >"$XDG_CACHE_HOME/pick/repos"
  run bash "$PICK"
  [ "$status" -eq 0 ]
  grep -Fx "gh repo clone you/feedbox $HOME/projects/feedbox" "$GH_LOG"
  grep -Fx "herdr workspace create --cwd $HOME/projects/feedbox --label feedbox --focus" "$HERDR_LOG"
}

@test "dispatch: unknown typed name creates the project after confirm" {
  dispatch_setup $'cool-tool'
  run bash "$PICK"
  [ "$status" -eq 0 ]
  [ -d "$HOME/projects/cool-tool" ]
  grep -Fx 'gh repo create you/cool-tool --private --source='"$HOME"'/projects/cool-tool --remote=origin' "$GH_LOG"
  grep -Fx "herdr workspace create --cwd $HOME/projects/cool-tool --label cool-tool --focus" "$HERDR_LOG"
}

@test "dispatch: missing editor binary leaves a plain pane" {
  dispatch_setup $'notes-api\nnotes-api'
  export PICK_EDIT_CMD='definitely-not-a-real-editor-xyz .'
  mkdir -p "$HOME/projects/notes-api"
  run bash "$PICK"
  [ "$status" -eq 0 ]
  grep -F 'herdr pane split' "$HERDR_LOG"
  ! grep -q 'pane run' "$HERDR_LOG"
}

@test "dispatch: empty PICK_EDIT_CMD leaves a plain pane" {
  dispatch_setup $'notes-api\nnotes-api'
  export PICK_EDIT_CMD=''
  mkdir -p "$HOME/projects/notes-api"
  run bash "$PICK"
  [ "$status" -eq 0 ]
  grep -F 'herdr pane split' "$HERDR_LOG"
  ! grep -q 'pane run' "$HERDR_LOG"
}

@test "dispatch: unknown typed name with Cancel does nothing" {
  dispatch_setup $'cool-tool'
  FZF_LATER_PICK=first run bash "$PICK"
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/projects/cool-tool" ]
  ! grep -q 'repo create' "$GH_LOG"
  ! grep -q 'workspace create' "$HERDR_LOG"
}

@test "dispatch: unknown prefix bounces instead of creating" {
  dispatch_setup $'wrk/thing'
  run bash "$PICK"
  [ "$status" -eq 1 ]
  ! grep -q 'repo create' "$GH_LOG"
  ! grep -q 'workspace create' "$HERDR_LOG"
}
