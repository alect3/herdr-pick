# herdr-pick, Salt formula for the herdr workspace + project picker.
#
# https://github.com/alect3/herdr-pick
#
# Deploys the picker and its repo-cache refresher into your $HOME, seeds
# an example config, and enables the systemd --user timer that keeps the
# cache fresh. It intentionally does NOT manage your herdr config.toml -
# that file is yours; see the README for the one keybinding snippet to
# add by hand.
#
# Run it from a checkout of this repo, as your own user (everything
# lives in $HOME, so no root is needed):
#
#   salt-call --local --file-root="$PWD" state.apply herdr-pick
#
# fzf/jq/git/gh must already be installed (your package manager), or run
# this as root with package installation opted in:
#
#   sudo salt-call --local --file-root="$PWD" --local \
#     pillar='{"herdr_pick": {"user": "alec", "home": "/home/alec",
#                             "install_pkgs": true}}' \
#     state.apply herdr-pick
#
# (Package names vary by distro, gh is "github-cli" on Arch, so the
# list is pillar-overridable via herdr_pick:pkgs.)
#
# The formula takes user/home/group from the environment with pillar
# overrides. In a real fleet setup (this repo was extracted from one)
# the same states run from a fileserver formula with pillar-supplied
# values and no environment defaults.

{% set user = salt['pillar.get']('herdr_pick:user', salt['environ.get']('USER', salt['cmd.run']('id -un'))) %}
{% set _info = salt['user.info'](user) or {} %}
{% set home = salt['pillar.get']('herdr_pick:home', salt['environ.get']('HOME', _info.get('home', '/home/' ~ user))) %}
{% set group = salt['pillar.get']('herdr_pick:group', (_info.get('groups') or [user]) | first) %}

# Package installation is opt-in: pkg.installed needs root, while the
# rest of this formula is designed to run unprivileged. Defaults match
# the Debian/Ubuntu names; override the whole list via herdr_pick:pkgs
# for your distro (Arch: fzf jq git github-cli).
{% if salt['pillar.get']('herdr_pick:install_pkgs', False) %}
{% for pkg in salt['pillar.get']('herdr_pick:pkgs', ['fzf', 'jq', 'git', 'gh']) %}
herdr-pick-pkg-{{ pkg }}:
  pkg.installed:
    - name: {{ pkg }}
{% endfor %}
{% endif %}

{{ home }}/.local/bin/herdr-pick:
  file.managed:
    - source: salt://herdr-pick/files/herdr-pick.sh
    - user: {{ user }}
    - group: {{ group }}
    - mode: '0755'
    - makedirs: True

{{ home }}/.local/bin/pick-repos-refresh:
  file.managed:
    - source: salt://herdr-pick/files/pick-repos-refresh.sh
    - user: {{ user }}
    - group: {{ group }}
    - mode: '0755'
    - makedirs: True

# Seed the config but never clobber one: replace: False writes the
# example only if the path does not exist yet, so user edits stick (and
# formula updates don't stomp them). Delete the file to re-seed.
{{ home }}/.config/herdr-pick/pick.conf:
  file.managed:
    - source: salt://herdr-pick/files/pick.conf
    - user: {{ user }}
    - group: {{ group }}
    - mode: '0644'
    - makedirs: True
    - replace: False

{{ home }}/.config/systemd/user/pick-repos-refresh.service:
  file.managed:
    - source: salt://herdr-pick/files/pick-repos-refresh.service
    - user: {{ user }}
    - group: {{ group }}
    - mode: '0644'
    - makedirs: True

{{ home }}/.config/systemd/user/pick-repos-refresh.timer:
  file.managed:
    - source: salt://herdr-pick/files/pick-repos-refresh.timer
    - user: {{ user }}
    - group: {{ group }}
    - mode: '0644'
    - makedirs: True

# There's no service.running for --user units, so enablement is a cmd.run
# as the user, gated by onchanges on the unit files (re-runs
# daemon-reload + enable whenever a unit changes). XDG_RUNTIME_DIR lets
# `systemctl --user` reach the user manager; it's derived at run time so
# the state also renders on hosts without the user. `start --no-block`
# warms the cache now without failing the state when the keyring is
# locked (a blocking start of the oneshot would exit non-zero).
herdr-pick-pick-repos-refresh-enable:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u {{ user }})}"
        systemctl --user daemon-reload
        systemctl --user enable --now pick-repos-refresh.timer
        systemctl --user start --no-block pick-repos-refresh.service
    - runas: {{ user }}
    - onchanges:
      - file: {{ home }}/.config/systemd/user/pick-repos-refresh.service
      - file: {{ home }}/.config/systemd/user/pick-repos-refresh.timer
    - require:
      - file: {{ home }}/.local/bin/pick-repos-refresh
