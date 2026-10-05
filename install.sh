#!/usr/bin/env bash
# Install herdr-pick without Salt: copies the scripts into ~/.local/bin,
# seeds the example config, and enables the systemd --user timer that
# keeps the repo cache fresh.
#
# Salt users: skip this and see the README's "Install with Salt" section
#, the same files deploy via the herdr-pick formula in this repo.
#
# Requirements this script does not install: herdr (https://herdr.dev),
# fzf, jq, git, gh (with `gh auth login` done).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-pick"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$bin_dir"
install -m 0755 "$root/herdr-pick/files/herdr-pick.sh" "$bin_dir/herdr-pick"
install -m 0755 "$root/herdr-pick/files/pick-repos-refresh.sh" "$bin_dir/pick-repos-refresh"

mkdir -p "$conf_dir"
if [[ -e "$conf_dir/pick.conf" ]]; then
  echo "keeping existing $conf_dir/pick.conf"
else
  install -m 0644 "$root/herdr-pick/files/pick.conf" "$conf_dir/pick.conf"
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user &>/dev/null; then
  mkdir -p "$unit_dir"
  install -m 0644 "$root/herdr-pick/files/pick-repos-refresh.service" "$unit_dir/"
  install -m 0644 "$root/herdr-pick/files/pick-repos-refresh.timer" "$unit_dir/"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  systemctl --user daemon-reload
  systemctl --user enable --now pick-repos-refresh.timer
  systemctl --user start --no-block pick-repos-refresh.service
else
  echo "no user systemd found; run pick-repos-refresh by hand (or from cron) to build the repo cache"
fi

cat <<'EOF'

Done. Next steps:

1. Install herdr (https://herdr.dev), plus fzf, jq, git and gh, and run
   `gh auth login` once so the repo cache can list your repos.
2. Bind the picker inside herdr: add to ~/.config/herdr/config.toml

     [[keys.command]]
     key = "prefix+s"
     type = "pane"
     command = "~/.local/bin/herdr-pick"
     description = "pick a workspace or project"

   (an absolute path is safest, use your real home), then
   `herdr server reload-config`.
3. Tweak ~/.config/herdr-pick/pick.conf to map your project dirs and
   GitHub owners.

Open herdr and press prefix+s.
EOF
