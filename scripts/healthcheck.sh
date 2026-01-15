#!/usr/bin/env bash
set -euo pipefail

# Do not allow running as root.
# If this triggers, the WSL default user is misconfigured.
if [ "$(id -u)" -eq 0 ]; then
  cat >&2 <<'EOF'
ERROR: setup.sh must NOT be run as root.

This indicates that the WSL default user is not set correctly.
Fix it by running the Windows bootstrap script again, or by setting
the default user for this distro manually.

Verify with:
  id -un

Expected: your normal user (not root)
EOF
  exit 1
fi

if [ ! -d "$HOME" ] || [ "$HOME" = "/" ]; then
  echo "ERROR: HOME is invalid ('$HOME'). Aborting." >&2
  exit 1
fi

profile="${1:-}"

usage() {
  echo "Usage: $0 <work|uni|private>" >&2
}

if [[ -z "$profile" ]]; then
  usage
  exit 2
fi

case "$profile" in
  work|uni|private) ;;
  *)
    echo "[healthcheck] ERROR: invalid profile '$profile'" >&2
    usage
    exit 2
    ;;
esac

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[healthcheck] ERROR: ansible-playbook not found. Run ./scripts/setup.sh $profile first." >&2
  exit 1
fi

echo "[healthcheck] Running healthcheck for profile: $profile"
ansible-playbook playbooks/healthcheck.yml -e "wsl_profile=$profile"
