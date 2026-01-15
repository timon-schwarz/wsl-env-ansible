#!/usr/bin/env bash
set -euo pipefail

log() { printf '[setup] %s\n' "$*"; }
err() { printf '[setup] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/setup.sh <work|uni|private>

This script is intended to be run inside the repo, even if the repo is located on /mnt/c.
It will clone the repo into the WSL Linux filesystem (under your home directory) and run
convergence from there.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

PROFILE="$1"
case "$PROFILE" in
  work|uni|private) ;;
  *)
    err "Invalid profile '$PROFILE' (expected: work|uni|private)"
    usage
    exit 2
    ;;
esac

command -v sudo >/dev/null 2>&1 || { err "sudo not found"; exit 1; }
command -v dnf  >/dev/null 2>&1 || { err "dnf not found (are you on Fedora?)"; exit 1; }

# --- Why we clone into the Linux filesystem ---
# When a repo is located under /mnt/c (NTFS), WSL often reports permissive permissions
# (effectively “world-writable”). Ansible treats this as unsafe and ignores ansible.cfg
# found in that directory, which breaks inventory/config discovery and causes confusing
# warnings like:
#   "Ansible is being run in a world writable directory ... ignoring it as an ansible.cfg source."
#
# To avoid this, we run Ansible from a clone inside the Linux filesystem (ext4), e.g. ~/src,
# where permissions behave as expected and Ansible will honor ansible.cfg normally.

# Ensure we can determine the repo URL from git.
if ! command -v git >/dev/null 2>&1; then
  log "Installing git (required to clone the repo)..."
  sudo dnf install -y git
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "This script must be run from within the repository so it can discover the origin URL."
  err "Hint: cd into the repo on Windows or Linux and run: ./scripts/setup.sh ${PROFILE}"
  exit 1
fi

REPO_URL="$(git config --get remote.origin.url || true)"
if [[ -z "${REPO_URL}" ]]; then
  err "Could not determine remote.origin.url. Ensure the repo has an 'origin' remote."
  err "Hint: git remote -v"
  exit 1
fi

TARGET_BASE="${HOME}/src"
TARGET_DIR="${TARGET_BASE}/wsl-ansible"

log "Profile: ${PROFILE}"
log "Repo origin: ${REPO_URL}"
log "Linux clone target: ${TARGET_DIR}"

mkdir -p "${TARGET_BASE}"

if [[ ! -d "${TARGET_DIR}/.git" ]]; then
  log "Cloning repo into Linux filesystem..."
  git clone "${REPO_URL}" "${TARGET_DIR}"
else
  # Respect your preference: do not auto-update. Just ensure the remote matches.
  existing_url="$(git -C "${TARGET_DIR}" config --get remote.origin.url || true)"
  if [[ -n "${existing_url}" && "${existing_url}" != "${REPO_URL}" ]]; then
    err "Existing clone at ${TARGET_DIR} points to a different origin:"
    err "  existing: ${existing_url}"
    err "  expected: ${REPO_URL}"
    err "Resolve this manually (delete the directory or fix the remote), then re-run."
    exit 1
  fi
  log "Linux clone already exists; not updating it automatically (by design)."
  log "If you want updates, run: git -C \"${TARGET_DIR}\" pull"
fi

log "Installing prerequisites (ansible + dependencies)..."
sudo dnf install -y \
  python3 \
  python3-libselinux \
  ansible

log "Running full converge from Linux filesystem clone..."
cd "${TARGET_DIR}"
./scripts/converge.sh "${PROFILE}"
