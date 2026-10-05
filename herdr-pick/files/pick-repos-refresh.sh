#!/usr/bin/env bash
# pick-repos-refresh: refresh the GitHub repo cache `herdr-pick` reads to
# offer not-yet-cloned repos as clone targets (the "↓ <name>" tier).
#
# https://github.com/alect3/herdr-pick
#
# Writes ~/.cache/pick/repos, one "owner/repo" per line, across the
# owners configured in PICK_OWNERS (see pick.conf), archived repos
# omitted. `herdr-pick` reads this file only, it never calls gh, so the
# menu is instant regardless of repo count. Owners are listed in
# precedence order: earlier owners win a basename clash in the picker, so
# put personal before work.
#
# With no PICK_OWNERS configured, the authenticated gh user's repos are
# listed (`gh api user`), which is the zero-config default.
#
# Atomic + keep-last-good: build into a temp file; only if every listing
# exits 0 AND the result is non-empty do we mv it over the cache. On any
# failure (locked keyring, offline, logged out) the previous cache is
# left untouched and we exit non-zero. A locked vault degrades the picker
# to a stale-but-correct remote tier, never an empty one.
#
# gh resolves its token from your keyring / agent (on Linux desktops
# typically the secret service), only available in an unlocked session -
# so this runs as the user, in-session (driven by the
# pick-repos-refresh.timer systemd --user unit shipped alongside), never
# as root or from a system cron.

set -euo pipefail

declare -a PICK_OWNERS=()
CONF="${HERDR_PICK_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pick/pick.conf}"
# shellcheck disable=SC1090  # config is user-supplied by design
[[ -f "$CONF" ]] && source "$CONF"

# resolve_default_owner: same rule as herdr-pick, PICK_DEFAULT_OWNER
# wins, else the authenticated gh user. Used only when PICK_OWNERS is
# unset/empty.
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

if [[ ${#PICK_OWNERS[@]} -eq 0 ]]; then
  PICK_OWNERS=("$(resolve_default_owner)")
  [[ -n "${PICK_OWNERS[0]}" ]] || {
    echo "pick-repos-refresh: no PICK_OWNERS configured and no gh user; keeping last-good cache" >&2
    exit 1
  }
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/pick"
cache="$cache_dir/repos"
mkdir -p "$cache_dir"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Each owner's listing is sorted so the cache is deterministic run-to-run;
# owners stay in PICK_OWNERS order (the picker's precedence order). A
# failed listing aborts before the mv, leaving the previous cache
# untouched.
for owner in "${PICK_OWNERS[@]}"; do
  if ! gh repo list "$owner" --no-archived --limit 1000 \
         --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null \
         | sort >>"$tmp"; then
    echo "pick-repos-refresh: 'gh repo list $owner' failed; keeping last-good cache" >&2
    exit 1
  fi
done

if [[ ! -s "$tmp" ]]; then
  echo "pick-repos-refresh: empty listing; keeping last-good cache" >&2
  exit 1
fi

mv -f "$tmp" "$cache"
trap - EXIT
