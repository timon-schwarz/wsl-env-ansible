#!/usr/bin/env bash
set -euo pipefail

info() { printf '\n[converge] %s\n' "$*"; }
die() { printf '\n[converge] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${#} -ne 1 ]]; then
  echo "Usage: $0 <work|uni|private>" >&2
  exit 2
fi
PROFILE="$1"

case "$PROFILE" in
  work|uni|private) ;;
  *) echo "Invalid profile: $PROFILE (expected work|uni|private)" >&2; exit 2;;
esac

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found. Run ./scripts/setup.sh <profile> first."

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

info "Full converge (packages + dotfiles + neovim) for profile: $PROFILE"

ansible-playbook playbooks/site.yml -e "wsl_profile=$PROFILE"
