#!/usr/bin/env bash
set -euo pipefail

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
