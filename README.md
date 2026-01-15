# WSL Environments (Fedora) — Ansible-managed Work / Uni / Private

This repository defines a reproducible, Ansible-managed “desired state” for three separate WSL distros:

* `fedora-work`
* `fedora-uni`
* `fedora-private`

Each distro is converged to its intended state via a single profile flag (`work|uni|private`). The design is intentionally low on variables: personal identity (git name/email, SSH config details, etc.) lives in dotfiles, not in Ansible variables.

The repo also provides:

* a full **setup** script for fresh distros,
* a full **converge** script to re-apply desired state,
* a fast **dotfiles-only** script for rapid iteration on dotfiles/Neovim,
* a Windows **PowerShell bootstrap** to clone the repo and create and start WSL distros.

---

## Goals

* Rebuild from scratch at any time on any Windows 11 host.
* Keep work/uni/private isolated by using separate WSL distros.
* Keep configuration readable and maintainable (role-based Ansible).
* Keep Neovim functional after every run (plugins installed automatically).
* Keep Ansible variables minimal and stable over time.

## Non-goals

* Managing Windows host state (VS Code install/extensions, fonts, Windows Terminal settings).
* Managing secrets (SSH private keys, tokens). You must handle those manually or via your own secure process.
* Perfect version pinning of system packages (Fedora + `dnf` is inherently “rolling within release”).

---

## High-level architecture

### Layers

1. **Windows-side lifecycle (WSL distros)**

   * Creation and naming of distros is handled with `wsl.exe` from Windows.
   * This repo provides a PowerShell helper (`windows/bootstrap.ps1`) to automate the initial setup.

2. **Linux-side convergence (Ansible)**

   * Ansible is the source of truth for packages and configuration deployment inside each distro.
   * A single profile argument controls the delta: `work|uni|private`.

3. **Dotfiles + Neovim**

   * Dotfiles are stored in this repo (and deployed via Ansible).
   * Git identity and similar “personal” details live in dotfiles.
   * Neovim config is deployed and plugins are installed so the editor is usable immediately.

---

## Repository layout (intended)

```
wsl-ansible/
  README.md

  ansible.cfg
  requirements.yml               # optional, used if we add galaxy collections

  inventories/
    localhost/
      hosts.yml
      group_vars/
        all.yml

  playbooks/
    site.yml                     # full converge
    dotfiles.yml                 # dotfiles + neovim only

  roles/
    wsl/
      tasks/main.yml

    common/
      tasks/main.yml
      tasks/packages.yml
      tasks/dirs.yml

    profile_work/
      tasks/main.yml
      tasks/packages.yml

    profile_uni/
      tasks/main.yml
      tasks/packages.yml

    profile_private/
      tasks/main.yml
      tasks/packages.yml

    dotfiles/
      tasks/main.yml

    neovim/
      tasks/main.yml

  files/
    dotfiles/
      common/...
      work/...
      uni/...
      private/...
    nvim/...

  scripts/
    setup.sh                     # install deps + ansible + full converge
    converge.sh                  # full converge
    dotfiles.sh                  # dotfiles-only converge

  windows/
    bootstrap.ps1                # clone repo + create/start distros + print next commands
```

---

## Profiles

Profiles represent intentional differences. Examples (not exhaustive):

* `work`: network tooling, work-specific repo conventions, work dotfile overlay
* `uni`: study toolchain, uni dotfile overlay
* `private`: personal utilities, private dotfile overlay

Profile selection is always explicit when running scripts:

* `work`
* `uni`
* `private`

No other environment variables are required.

---

## Quick start (Windows)

### Option A — PowerShell bootstrap (recommended)

From Windows PowerShell (not inside WSL):

1. Clone and bootstrap

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\bootstrap.ps1
```

2. The script will print the exact commands to run inside each distro to finish setup, e.g.:

```bash
cd /mnt/c/Users/<YOU>/src/wsl-ansible
./scripts/setup.sh work
```

### Option B — Manual WSL distro creation

If you prefer manual control:

* Create/import the three WSL distros and name them:

  * `fedora-work`
  * `fedora-uni`
  * `fedora-private`

Then inside each distro run the Linux-side setup below.

---

## Linux-side usage (inside each WSL distro)

### Full setup (fresh distro)

This installs dependencies, installs Ansible, and runs a full converge.

```bash
git clone <this-repo-url> ~/src/wsl-ansible
cd ~/src/wsl-ansible
./scripts/setup.sh work
```

### Full converge (re-apply desired state)

Use this periodically to ensure the environment matches the repo.

```bash
cd ~/src/wsl-ansible
./scripts/converge.sh work
```

### Dotfiles-only converge (fast iteration)

Use this while iterating on dotfiles/Neovim. It is designed to be fast and not touch system packages.

```bash
cd ~/src/wsl-ansible
./scripts/dotfiles.sh work
```

---

## What each script does

### `scripts/setup.sh <profile>`

* Validates profile argument.
* Installs prerequisites with `dnf` (git, python, ansible).
* Runs `scripts/converge.sh <profile>`.

### `scripts/converge.sh <profile>`

* Runs full playbook:

  * `playbooks/site.yml`
* Applies roles:

  * WSL checks
  * common packages/dirs
  * profile packages
  * dotfiles deployment
  * Neovim deployment + plugin installation

### `scripts/dotfiles.sh <profile>`

* Runs dotfiles-only playbook:

  * `playbooks/dotfiles.yml`
* Applies roles:

  * dotfiles deployment (common + profile overlay)
  * Neovim deployment + plugin installation

---

## Dotfiles model

Dotfiles are deployed from:

* `files/dotfiles/common/` (baseline)
* `files/dotfiles/<profile>/` (overlay)

Overlay precedence:

1. common
2. profile

Personal configuration (git identity, signing, includeIf rules, etc.) must be edited directly in these dotfiles.

The intended behavior:

* symlink where possible (so repo changes take effect immediately)
* back up existing files before first replacement if necessary

---

## Neovim model (always functional)

Neovim config is deployed to:

* `~/.config/nvim`

Plugins are installed on every run (full converge and dotfiles-only converge). The role will run a headless sync/install command suitable for the chosen plugin manager in `files/nvim/`.

---

## Ansible execution model

Inventory:

* local-only: `inventories/localhost/hosts.yml`
* connection: `local`
* privilege escalation: sudo (for `dnf` and system-level tasks)

Main full playbook:

* `playbooks/site.yml`

Dotfiles-only playbook:

* `playbooks/dotfiles.yml`

Profile selection is passed via `-e wsl_profile=<profile>` internally by scripts.

---

## Adding or changing packages

* Common packages: `roles/common/tasks/packages.yml`
* Profile packages:

  * `roles/profile_work/tasks/packages.yml`
  * `roles/profile_uni/tasks/packages.yml`
  * `roles/profile_private/tasks/packages.yml`

Guideline:

* If you need it in all environments, it belongs in `common`.
* If it is environment-specific, it belongs in the profile role.

---

## Extending dotfiles

Add or modify files under:

* `files/dotfiles/common/`
* `files/dotfiles/<profile>/`

Then apply quickly:

```bash
./scripts/dotfiles.sh work
```

---

## Windows PowerShell bootstrap expectations

`windows/bootstrap.ps1` is intended to be **run from the repository root** and does **not** clone or update the repository.

Expected usage model:

* You manually clone this repository wherever you want on Windows.
* You `cd` into the repository root.
* You run the bootstrap script from there.

The script will:

* verify it is executed from the repo root (fails fast otherwise)
* create and start the three distros (`fedora-work`, `fedora-uni`, `fedora-private`)
* print the exact commands to run inside each distro to complete setup

If the script is run from the wrong directory, it will exit with a clear error explaining what to do.

---

## VS Code workflow (expected)

* Install VS Code + WSL extension on Windows.
* Use “Remote - WSL” to open folders inside the distros.

Neovim extension notes:

* The environment ensures `nvim` exists and plugins are installed.
* VS Code extension configuration remains on the Windows side.

---

## Troubleshooting

### `sudo` issues

* Ensure your user is in sudoers in the Fedora WSL image.

### Package install failures

```bash
sudo dnf clean all
sudo dnf makecache
```

### Neovim plugin failures

```bash
./scripts/dotfiles.sh work
```

---

## Security notes

* Do not store secrets in this repo.
* Do not bake SSH private keys into exported distro tarballs.

---

## Implementation status

This README is the specification. The implementation will be built to match it exactly.
