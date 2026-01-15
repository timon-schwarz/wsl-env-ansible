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


log() { printf '[setup] %s\n' "$*"; }
err() { printf '[setup] ERROR: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/setup.sh <work|uni|private>

This script may be run from a Windows-mounted working copy (/mnt/c/...).
It clones the repo into the WSL Linux filesystem (~/src/...) and runs converge from there.

Note: The bootstrap clone uses HTTPS if SSH keys are not yet configured.
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
# warnings.
# Running from a clone inside the Linux filesystem (ext4) avoids this.
#
# --- Why we may clone via HTTPS during setup ---
# The repo on Windows might use an SSH remote (git@github.com:...).
# On a fresh WSL distro, SSH keys typically are not configured yet, so cloning via SSH fails.
# Therefore, setup clones via HTTPS (no keys required) for the initial bootstrap.
# After SSH keys are set up later, you can switch remotes back to SSH.

# Ensure git exists (needed to discover origin and clone)
if ! command -v git >/dev/null 2>&1; then
  log "Installing git (required to clone the repo)..."
  sudo dnf install -y git
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "This script must be run from within the repository so it can discover the origin URL."
  err "Hint: cd into the repo and run: ./scripts/setup.sh ${PROFILE}"
  exit 1
fi

REPO_URL="$(git config --get remote.origin.url || true)"
if [[ -z "${REPO_URL}" ]]; then
  err "Could not determine remote.origin.url. Ensure the repo has an 'origin' remote."
  err "Hint: git remote -v"
  exit 1
fi

# Convert SSH-style GitHub URL to HTTPS for bootstrap clone
# Examples:
#   git@github.com:timon-schwarz/wsl-env-ansible.git  -> https://github.com/timon-schwarz/wsl-env-ansible.git
#   ssh://git@github.com/timon-schwarz/wsl-env-ansible.git -> https://github.com/timon-schwarz/wsl-env-ansible.git
REPO_URL_HTTPS="$REPO_URL"
if [[ "$REPO_URL" =~ ^git@github\.com: ]]; then
  REPO_URL_HTTPS="https://github.com/${REPO_URL#git@github.com:}"
elif [[ "$REPO_URL" =~ ^ssh://git@github\.com/ ]]; then
  REPO_URL_HTTPS="https://github.com/${REPO_URL#ssh://git@github.com/}"
fi

TARGET_BASE="${HOME}/src"
TARGET_DIR="${TARGET_BASE}/wsl-ansible"

log "Profile: ${PROFILE}"
log "Repo origin: ${REPO_URL}"
log "Bootstrap clone URL: ${REPO_URL_HTTPS}"
log "Linux clone target: ${TARGET_DIR}"

mkdir -p "${TARGET_BASE}"


if [[ ! -d "${TARGET_DIR}/.git" ]]; then
  log "Cloning repo into Linux filesystem..."
  git clone "${REPO_URL_HTTPS}" "${TARGET_DIR}"
else
  log "Linux clone already exists."

  cd "${TARGET_DIR}"

  # Ensure we are on a branch (not detached HEAD)
  if ! git symbolic-ref -q HEAD >/dev/null; then
    err "Linux clone is in detached HEAD state."
    err "Resolve manually before running setup:"
    err "  cd ${TARGET_DIR} && git status"
    exit 1
  fi

  # Ensure working tree is clean
  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Linux clone has uncommitted changes."
    err "Resolve manually before running setup:"
    err "  cd ${TARGET_DIR} && git status"
    exit 1
  fi

  log "Updating Linux clone (fast-forward only)..."
  git pull --ff-only
fi


log "Installing prerequisites (ansible + dependencies)..."
sudo dnf install -y \
  python3 \
  python3-libselinux \
  ansible

log "Running full converge from Linux filesystem clone..."
cd "${TARGET_DIR}"
chmod +x ./scripts/*.sh || true
./scripts/converge.sh "${PROFILE}"

# Optional: if SSH is already usable, switch the Linux clone's origin back to SSH
# (So future pulls use SSH without you having to change anything.)
if command -v ssh >/dev/null 2>&1; then
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com >/dev/null 2>&1; then
    if [[ "$REPO_URL" =~ ^git@github\.com: ]]; then
      log "SSH auth to GitHub works; switching Linux clone origin back to SSH."
      git -C "${TARGET_DIR}" remote set-url origin "${REPO_URL}"
    fi
  else
    log "SSH auth to GitHub not available yet; leaving Linux clone origin as HTTPS."
    log "After you configure SSH keys, you may switch it with:"
    log "  git -C \"${TARGET_DIR}\" remote set-url origin \"${REPO_URL}\""
  fi
fi
