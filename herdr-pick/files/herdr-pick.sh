#!/usr/bin/env bash
# herdr-pick: unified workspace + project picker for herdr.
#
# https://github.com/alect3/herdr-pick
#
# Lists three tiers: every open herdr workspace (open destinations)
# first, then every project directory under the configured site dirs
# (see PICK_SITES below) that isn't already open, then every GitHub repo
# from the configured owners not yet cloned, read from a cache
# (~/.cache/pick/repos) that pick-repos-refresh keeps current, so the
# menu stays instant. Dedup is on name across all three tiers (workspace
# label == project basename == repo basename): a thing shows in its
# highest-fidelity tier only, open, else local, else clonable, never
# twice.
#
# Selection dispatch:
#   "● <name>" → focus that workspace, exit.
#   "↓ <name>" → clone that repo (its owner decides the destination dir),
#                then open it like any project.
#   "<name>"   → an existing local project: open a herdr workspace rooted
#                at it. A name matching nothing: CREATE it, a bare name
#                (and any configured prefix, like "work/") maps to a site
#                in PICK_SITES: the dir to create in and the GitHub owner
#                to mint a private repo under ("-" = local only). Creating
#                prompts a confirm (Cancel default) first, then opens it.
#
# Configuration is an optional shell file sourced at startup, by default
# ~/.config/herdr-pick/pick.conf (override with HERDR_PICK_CONF). Without
# it the picker works out of the box: projects live in ~/projects and
# personal repos belong to the authenticated gh user. See pick.conf in
# this repo for the full knob reference.
#
# Bound inside herdr at prefix+s via a `type = "pane"` key command (see
# the README), herdr opens it in a temporary pane and closes the pane
# when it exits. Also runnable by hand from any pane.
#
# Extracted from a Salt-managed fleet setup; the Salt formula that
# deploys it ships in this repo (herdr-pick/), and a plain install.sh
# covers non-Salt machines.

set -euo pipefail

# --- configuration -------------------------------------------------------
# An optional config file is sourced if present (it is plain shell). Every
# knob is optional and falls back to the defaults below; the knobs:
#
#   PICK_SITES        destination table, an array of "name:dir:owner":
#                       name   create prefix typed in the picker (matched
#                              case-insensitively); the FIRST site is also
#                              the bare-name destination and its dir is
#                              where unlisted owners clone to
#                       dir    parent dir, scanned for the local tier
#                              (first site with a dir wins a basename
#                              clash) and where that site's repos clone
#                       owner  GitHub owner for auto-created repos under
#                              this prefix; "-" = local only; empty = the
#                              default owner (PICK_DEFAULT_OWNER, else the
#                              authenticated `gh api user`, else local)
#   PICK_DEFAULT_OWNER  owner for sites with an empty owner field; when
#                       unset the picker asks `gh api user` (once, only
#                       when a create is actually requested)
#   PICK_OWNERS         GitHub owners for the repo cache (read by
#                       pick-repos-refresh, not by this script)
#   PICK_OWNER_DIR      optional map overriding where an owner's repos
#                       clone: PICK_OWNER_DIR[owner]=dir
#   PICK_EDIT_CMD       command run in the editor pane of an opened
#                       workspace (default "nvim .", skipped when nvim is
#                       not installed; set it empty for a plain shell)
declare -a PICK_SITES=()
declare -A PICK_OWNER_DIR=()
CONF="${HERDR_PICK_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pick/pick.conf}"
# shellcheck disable=SC1090  # config is user-supplied by design
[[ -f "$CONF" ]] && source "$CONF"

# Default destination table: one site, ~/projects, owner = default owner.
[[ ${#PICK_SITES[@]} -gt 0 ]] || PICK_SITES=("projects:$HOME/projects:")

# resolve_default_owner: who auto-created personal repos belong to.
# PICK_DEFAULT_OWNER wins (cached for the run); otherwise ask gh; an
# empty result means "local only". Guarded with timeout so a wedged
# network cannot hang the create flow.
_default_owner=""
resolve_default_owner() {
  if [[ -z "$_default_owner" ]]; then
    if [[ -n "${PICK_DEFAULT_OWNER:-}" ]]; then
      _default_owner="$PICK_DEFAULT_OWNER"
    else
      _default_owner="$(timeout 5 gh api user --jq .login 2>/dev/null || true)"
    fi
  fi
  printf '%s\n' "$_default_owner"
}

# clone_dest <owner>: where a repo owned by <owner> clones to. An explicit
# PICK_OWNER_DIR entry wins; else the dir of the first site owned by
# <owner>; else the first site's dir (the default destination). Pure given
# the config, so it's unit-testable in isolation.
clone_dest() {
  local owner="$1" site name dir o
  if [[ -n "${PICK_OWNER_DIR[$owner]:-}" ]]; then
    printf '%s\n' "${PICK_OWNER_DIR[$owner]}"
    return 0
  fi
  for site in "${PICK_SITES[@]}"; do
    IFS=: read -r name dir o <<<"$site"
    if [[ -n "$o" && "$o" != "-" && "$o" == "$owner" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  IFS=: read -r _ dir _ <<<"${PICK_SITES[0]}"
  printf '%s\n' "$dir"
}

# notify <message>: surface feedback as a herdr in-app toast (the picker
# always runs inside a herdr pane), with a stderr echo as the fallback
# trace while the temporary pane is still visible.
notify() {
  herdr notification show "pick" --body "$1" >/dev/null 2>&1 || true
  echo "herdr-pick: $1" >&2
}

# open_project <name> <project_dir>: bring a project's workspace up.
#
# If a workspace labelled <name> is already open, focus it, re-picking
# an open project shouldn't reach this (dedup), but a typed name can.
# Otherwise create a workspace rooted at <project_dir> and lay out the
# standard two-pane project layout: an empty shell on the left to start a
# coding agent in, and the editor (PICK_EDIT_CMD) on the right.
#
# The explicit --label matters: it's the dedup key on the next run, so it
# must not be left to herdr's cwd-derived naming. --focus is load-bearing
# too: a CLI create does NOT focus by default (the workspace comes back
# focused:false), so without it the picker leaves you staring at the old
# workspace. An explicit focus survives the temporary picker pane closing
# (verified on herdr 0.7.1, which fixed the focus-revert of upstream issue
# #658).
#
# Layout: the workspace's root pane becomes the left/agent pane; we split
# it rightward for the editor (cwd = project so the editor opens in it)
# and launch PICK_EDIT_CMD there via `pane run`, then focus back left so
# the agent prompt is ready to type into. Every step past the create is
# best-effort: an API-shape change (unparseable pane id), a split failure,
# or the editor binary not being installed just degrades to the plain
# single-pane workspace rather than aborting the open. Assumes
# <project_dir> already exists, callers resolve/validate the path first.
open_project() {
  local name="$1" project_dir="$2" ws_id create left right
  ws_id="${open_ws[$name]:-}"
  if [[ -n "$ws_id" ]]; then
    herdr workspace focus "$ws_id" >/dev/null 2>&1 || true
    return 0
  fi

  create="$(herdr workspace create --cwd "$project_dir" --label "$name" \
              --focus 2>/dev/null)" || {
    notify "Could not create workspace '$name'."
    return 1
  }

  # Root pane == left/agent pane. If we can't read its id (API shift), the
  # workspace still opened as one pane, leave it at that.
  left="$(jq -r '.result.root_pane.pane_id // empty' <<<"$create" 2>/dev/null)"
  [[ -n "$left" ]] || return 0

  # Split right for the editor; --no-focus keeps focus on the left pane.
  # --ratio is the fraction kept by the ORIGINAL (left/agent) pane, so 0.33
  # leaves the agent a third and gives the editor two thirds.
  right="$(herdr pane split "$left" --direction right --cwd "$project_dir" \
             --ratio 0.33 --no-focus 2>/dev/null \
             | jq -r '.result.pane.pane_id // empty' 2>/dev/null)"
  [[ -n "$right" ]] || return 0

  # Launch the editor in the right pane, then make sure focus lands on the
  # left/agent pane regardless of split's focus behaviour. The default
  # "nvim ." opens the workspace cwd (nvim's explorer on the project)
  # rather than the dashboard start screen; the pane's cwd is already the
  # project (--cwd above), so "." resolves to it. An unset PICK_EDIT_CMD
  # falls back to nvim and is skipped when nvim isn't installed; a conf-set
  # command is trusted verbatim (set it empty for a plain shell).
  if [[ -n "${PICK_EDIT_CMD+x}" ]]; then
    herdr pane run "$right" "$PICK_EDIT_CMD" >/dev/null 2>&1 || true
  elif command -v nvim >/dev/null 2>&1; then
    herdr pane run "$right" "nvim ." >/dev/null 2>&1 || true
  fi
  herdr pane focus --direction left --pane "$right" >/dev/null 2>&1 || true
}

# parse_destination <typed-name> <default-owner>: resolve a CREATE target
# from a typed picker entry. On success echoes "<dest-dir>\t<remote-owner-
# or-->" using the PICK_SITES table: the entry's prefix is matched
# case-insensitively, a bare name falls to the FIRST site, and an empty
# site owner field falls to <default-owner> ("-" or an empty resolution =
# local only, no GitHub repo). Returns non-zero with no output for an
# unknown prefix ("Repsit/myapp", "foo/myapp"), a multi-level path, or an
# empty leaf, that's the typo guard: a mistyped prefix bounces rather
# than creating a garbage path. Pure: string parsing only, no filesystem/
# network side effects, so it's unit-testable in isolation.
parse_destination() {
  local input="$1" default_owner="$2" prefix rest site name dir owner
  if [[ "$input" != */* ]]; then
    [[ -z "$input" ]] && return 1
    IFS=: read -r _ dir owner <<<"${PICK_SITES[0]}"
  else
    prefix="${input%%/*}"
    rest="${input#*/}"
    [[ -z "$rest" || "$rest" == */* ]] && return 1
    for site in "${PICK_SITES[@]}"; do
      IFS=: read -r name dir owner <<<"$site"
      [[ "${prefix,,}" == "$name" ]] && break
      name="" dir="" owner=""
    done
    [[ -n "$dir" ]] || return 1
    input="$rest"
  fi
  if [[ "$owner" == "-" ]]; then
    owner="-"
  else
    owner="${owner:-$default_owner}"
    [[ -n "$owner" ]] || owner="-"
  fi
  printf '%s\t%s\n' "$dir/$input" "$owner"
}

# --- discover open workspaces ------------------------------------------
# label → workspace_id, from the running herdr server. The jq walks the
# whole response for objects carrying both workspace_id and label rather
# than assuming an envelope shape, so a socket-API layout change doesn't
# silently empty the tier. First-wins on a duplicate label (shouldn't
# happen, labels are the picker's identity contract).
declare -A open_ws=()
open_names=()
if ws_json="$(herdr workspace list 2>/dev/null)"; then
  while IFS=$'\t' read -r id label; do
    [[ -n "$id" && -n "$label" ]] || continue
    [[ -n "${open_ws[$label]:-}" ]] && continue
    open_ws["$label"]="$id"
    open_names+=("$label")
  done < <(jq -r '
      [.. | objects | select(has("workspace_id") and has("label"))]
      | unique_by(.workspace_id) | sort_by(.label)
      | .[] | [.workspace_id, .label] | @tsv' <<<"$ws_json" 2>/dev/null)
else
  notify "Cannot reach the herdr server, is this pane inside herdr?"
  exit 1
fi

# --- discover projects on disk ----------------------------------------
# Scan each site's dir in table order; first-wins on basename collision
# (earlier sites beat later ones).
declare -A project_paths=()
projects=()
seen_dir=""
for site in "${PICK_SITES[@]}"; do
  IFS=: read -r _ dir _ <<<"$site"
  [[ -n "$dir" && "$dir" != "$seen_dir" ]] || continue
  seen_dir="$dir"
  [[ -d "$dir" ]] || continue
  while IFS= read -r d; do
    base="$(basename "$d")"
    [[ "$base" == *.worktrees ]] && continue
    [[ "$base" == .* ]] && continue
    if [[ -z "${project_paths[$base]:-}" ]]; then
      project_paths["$base"]="$d"
      projects+=("$base")
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d | sort)
done

# --- discover clonable repos from cache -------------------------------
# pick-repos-refresh keeps ~/.cache/pick/repos current (one "owner/repo"
# per line, earlier owners first). We read it only, never call gh here -
# so the menu stays instant regardless of repo count. A repo already
# cloned (a project dir) or open (a workspace) is filtered out so it
# shows in its higher-fidelity tier, never twice. First-wins on basename
# collision across owners: the cache lists owners in precedence order, so
# a personal repo wins a clash with a work one.
declare -A repo_owner=()        # basename -> owner/repo
remote_names=()
repo_cache="${XDG_CACHE_HOME:-$HOME/.cache}/pick/repos"
if [[ -f "$repo_cache" ]]; then
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    base="${slug##*/}"
    [[ -n "${project_paths[$base]:-}" ]] && continue
    [[ -n "${open_ws[$base]:-}" ]] && continue
    [[ -n "${repo_owner[$base]:-}" ]] && continue
    repo_owner["$base"]="$slug"
    remote_names+=("$base")
  done < "$repo_cache"
fi

# --- build picker list ------------------------------------------------
# Open workspaces first (● prefix), then closed local projects, then
# clonable repos (↓ prefix); alphabetical within each group.
lines=()
for n in "${open_names[@]}"; do
  lines+=("● $n")
done
for p in "${projects[@]}"; do
  [[ -n "${open_ws[$p]:-}" ]] && continue
  lines+=("$p")
done
if [[ ${#remote_names[@]} -gt 0 ]]; then
  while IFS= read -r r; do
    lines+=("↓ $r")
  done < <(printf '%s\n' "${remote_names[@]}" | sort)
fi

if [[ ${#lines[@]} -eq 0 ]]; then
  notify "No workspaces or projects found."
  exit 0
fi

# --- fzf prompt ---------------------------------------------------------
# --print-query emits the typed query on line 1 and the selection (if
# any) on line 2. Enter on a highlighted entry dispatches the selection;
# Enter with nothing matching (exit 1, query only) treats the typed name
# as a CREATE request. Esc / ctrl-c (exit 130) aborts quietly. An
# accidental Enter lands on the highlighted entry, so CREATE only fires
# when the query matches nothing at all.
fzf_status=0
fzf_out="$(printf '%s\n' "${lines[@]}" | fzf --print-query --prompt='> ')" \
  || fzf_status=$?
if [[ "$fzf_status" -ge 2 ]]; then
  exit 0
fi
query="$(sed -n '1p' <<<"$fzf_out")"
sel="$(sed -n '2p' <<<"$fzf_out")"
[[ -n "$sel" ]] || sel="$query"
[[ -n "$sel" ]] || exit 0

# --- dispatch: focus an open workspace ----------------------------------
if [[ "$sel" == "● "* ]]; then
  name="${sel#● }"
  ws_id="${open_ws[$name]:-}"
  if [[ -n "$ws_id" ]]; then
    herdr workspace focus "$ws_id" >/dev/null 2>&1 || true
  fi
  exit 0
fi

# --- dispatch: clone a not-yet-local repo -----------------------------
# "↓ <name>" came from the cache tier. Clone it to the dir its owner maps
# to (clone_dest: PICK_OWNER_DIR override, else the first site owned by
# the owner, else the first site's dir), then open it like any project.
# open_project assumes the dir exists, so we only call it once the clone
# has actually landed.
if [[ "$sel" == "↓ "* ]]; then
  name="${sel#↓ }"
  slug="${repo_owner[$name]:-}"
  if [[ -z "$slug" ]]; then
    notify "No cached repo '$name'."
    exit 1
  fi
  dest="$(clone_dest "${slug%%/*}")/$name"
  # Cache can lag reality: if it's already on disk, just open it.
  if [[ -e "$dest" ]]; then
    open_project "$name" "$dest"
    exit 0
  fi
  notify "Cloning $slug…"
  if gh repo clone "$slug" "$dest" >/dev/null 2>&1; then
    # Tidy the cache so the now-local repo drops off the clonable tier.
    # (The local-dir dedup already hides it next run; this just keeps the
    # cache honest.) Best-effort, backgrounded, no-op until installed.
    refresh="$HOME/.local/bin/pick-repos-refresh"
    if [[ -x "$refresh" ]]; then
      setsid -f "$refresh" >/dev/null 2>&1 || true
    fi
    open_project "$name" "$dest"
  else
    notify "Clone failed: $slug"
    exit 1
  fi
  exit 0
fi

# --- dispatch: open a local project, or create a new one --------------
name="$sel"

# An existing local project (selected from the local tier, or typed): open.
project_dir="${project_paths[$name]:-}"
if [[ -n "$project_dir" ]]; then
  open_project "$name" "$project_dir"
  exit 0
fi
# A typed name that's actually an open workspace: focus it rather than
# create a colliding project.
if [[ -n "${open_ws[$name]:-}" ]]; then
  herdr workspace focus "${open_ws[$name]}" >/dev/null 2>&1 || true
  exit 0
fi

# Matched nothing → the typed name is a request to CREATE a project.
# parse_destination applies the site table (a mistyped prefix is rejected
# rather than creating a garbage path).
if ! parsed="$(parse_destination "$name" "$(resolve_default_owner)")"; then
  prefix_list=""
  for site in "${PICK_SITES[@]}"; do
    IFS=: read -r site_name _ _ <<<"$site"
    prefix_list+=" ${site_name}/"
  done
  notify "Unknown destination '$name': try a bare name, or one of:${prefix_list% }"
  exit 1
fi
IFS=$'\t' read -r dest remote <<<"$parsed"
base="${dest##*/}"

# Idempotent: if the target already exists on disk, just open it.
if [[ -e "$dest" ]]; then
  open_project "$base" "$dest"
  exit 0
fi

# Confirm before creating anything, a bare name can mint a real private
# GitHub repo. "Cancel" is listed first so it's the default-highlighted
# entry: a reflexive Enter, or Escape, aborts; only picking the Create
# line acts.
if [[ "$remote" != "-" ]]; then
  confirm_label="Create $dest  +  private $remote/$base repo"
else
  confirm_label="Create $dest  (local only)"
fi
choice="$(printf '%s\n%s\n' "Cancel" "$confirm_label" \
            | fzf --prompt='create? ')" || exit 0
[[ "$choice" == "$confirm_label" ]] || exit 0

if ! mkdir -p "$dest"; then
  notify "Could not create $dest."
  exit 1
fi
git -C "$dest" init -q >/dev/null 2>&1 || true

if [[ "$remote" != "-" ]]; then
  # Personal project: create a private GitHub repo and wire it as origin.
  # If the remote already exists (e.g. a stale cache), don't fail, keep
  # the local repo and say so. No --push: a fresh init has no commits.
  notify "Creating $remote/$base…"
  if gh repo create "$remote/$base" --private --source="$dest" \
       --remote=origin >/dev/null 2>&1; then
    refresh="$HOME/.local/bin/pick-repos-refresh"
    if [[ -x "$refresh" ]]; then
      setsid -f "$refresh" >/dev/null 2>&1 || true
    fi
  else
    notify "$remote/$base: remote not created (exists?); local only."
  fi
fi

open_project "$base" "$dest"
