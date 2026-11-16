#!/bin/sh
# dotfiles-bootstrap — set up chezmoi + the private dotfiles repo on a NEW machine.
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/Troublesis/dotfiles-bootstrap/main/bootstrap.sh)"
#
# Use that exact form (not `curl | sh`) so stdin stays your terminal for prompts.
# Safe to re-run: every phase checks what is already done.
#
# Phases:  1 preflight → 2 chezmoi binary → 3 age key → 4 repo access → 5 init+apply → 6 summary
#
# Environment (all optional):
#   DOTFILES_REPO     repo to clone         (default git@github.com:Troublesis/dotfiles.git)
#   AGE_KEY_FILE      path to an existing age key.txt to install
#   AGE_KEY_FROM      user@host to scp ~/.config/chezmoi/key.txt from
#   GITHUB_TOKEN      read-only PAT for a ONE-TIME https clone of the private repo (never stored)
#   CHEZMOI_ARGS      extra args for `chezmoi init --apply`
#   BOOTSTRAP_YES=1   no prompts at all (chezmoi uses its defaults; key/deploy-key steps are skipped)
#
# This script contains no secrets. The age key is what unlocks the encrypted dotfiles.

set -u

REPO="${DOTFILES_REPO:-git@github.com:Troublesis/dotfiles.git}"
GH_SLUG="Troublesis/dotfiles"
SRC="$HOME/.local/share/chezmoi"
KEY="$HOME/.config/chezmoi/key.txt"
BIN="$HOME/.local/bin"
DEPLOY_KEY="$HOME/.ssh/id_ed25519_dotfiles"
KEY_RE='^AGE-SECRET-KEY-1[A-Z0-9]{58}[[:space:]]*$'
WARNINGS=""

# ── helpers ──────────────────────────────────────────────────────────────────
say()  { printf '\033[34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[33m ! \033[0m %s\n' "$*"; WARNINGS="${WARNINGS}  - $*
"; }
die()  { printf '\033[31m ✗ \033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }
# /dev/tty can exist yet be unopenable (no controlling terminal: ssh without -t, cron, CI) → really try it.
have_tty() { ( : </dev/tty ) 2>/dev/null; }
interactive() { [ "${BOOTSTRAP_YES:-}" != 1 ] && have_tty; }
ask() { printf '%s' "$1" >/dev/tty; IFS= read -r REPLY </dev/tty || REPLY=""; }
ask_secret() {
  printf '%s' "$1" >/dev/tty
  stty -echo </dev/tty 2>/dev/null
  IFS= read -r REPLY </dev/tty || REPLY=""
  stty echo </dev/tty 2>/dev/null
  printf '\n' >/dev/tty
}
is_github_repo() { case "$REPO" in git@github.com:*|https://github.com/*|ssh://git@github.com/*) return 0 ;; *) return 1 ;; esac; }

# ── 1. preflight ─────────────────────────────────────────────────────────────
preflight() {
  say "1/6 Preflight"
  OS=$(uname -s); ARCH=$(uname -m)
  case "$OS" in
    Linux|Darwin) ;;
    *) die "Unsupported OS '$OS'. On Windows use setup.ps1 from the dotfiles repo (see README)." ;;
  esac
  need curl || die "curl is required — install it first (e.g. 'sudo yum install -y curl')."
  need tar  || die "tar is required."
  mkdir -p "$BIN"
  PATH="$BIN:$HOME/bin:/usr/local/bin:$PATH"; export PATH
  need git || warn "git not found — chezmoi will use its built-in git (HTTPS only)."
  ok "$OS/$ARCH, curl present, bin dir $BIN"
}

# ── 2. chezmoi binary ────────────────────────────────────────────────────────
chezmoi_ok() { need chezmoi && chezmoi --version >/dev/null 2>&1; }

install_chezmoi_musl() {   # static build: runs on any glibc (e.g. CentOS/Oracle Linux 7)
  [ "$OS" = Linux ] || return 1
  case "$ARCH" in x86_64|amd64) a=amd64 ;; aarch64|arm64) a=arm64 ;; *) return 1 ;; esac
  tag=$(curl -fsSL --connect-timeout 10 https://api.github.com/repos/twpayne/chezmoi/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
  [ -n "$tag" ] || return 1
  tmp=$(mktemp -d) || return 1
  curl -fsSL --connect-timeout 20 "https://github.com/twpayne/chezmoi/releases/download/$tag/chezmoi_${tag#v}_linux-musl_${a}.tar.gz" \
    | tar -xz -C "$tmp" chezmoi 2>/dev/null && install -m 0755 "$tmp/chezmoi" "$BIN/chezmoi"
  rc=$?; rm -rf "$tmp"; return "$rc"
}

ensure_chezmoi() {
  say "2/6 chezmoi"
  if chezmoi_ok; then ok "chezmoi $(chezmoi --version | cut -d, -f1 | cut -d' ' -f3) already installed"; return; fi
  if [ "$OS" = Darwin ] && need brew; then brew install chezmoi >/dev/null 2>&1; fi
  chezmoi_ok || sh -c "$(curl -fsSL https://get.chezmoi.io)" -- -b "$BIN" >/dev/null 2>&1
  chezmoi_ok || install_chezmoi_musl
  chezmoi_ok || die "Could not install a working chezmoi. See https://www.chezmoi.io/install/"
  ok "installed chezmoi to $(command -v chezmoi)"
}

# ── 3. age key ───────────────────────────────────────────────────────────────
key_valid() { [ -f "$1" ] && grep -Eq "$KEY_RE" "$1"; }

install_key_from() {   # $1 = file that contains an AGE-SECRET-KEY line
  key_valid "$1" || return 1
  mkdir -p "$(dirname "$KEY")" && chmod 700 "$(dirname "$KEY")"
  ( umask 077; grep -E "$KEY_RE" "$1" | head -1 > "$KEY" )
  chmod 600 "$KEY"
}

ensure_age_key() {
  say "3/6 Age key (unlocks the encrypted dotfiles: ~/.zsh_secrets, tokens, ssh keys)"
  if key_valid "$KEY"; then ok "valid key at $KEY"; return; fi
  if [ -f "$KEY" ]; then
    mv "$KEY" "$KEY.invalid.$(date +%s)"
    warn "existing $KEY was malformed (wrapped/pasted?) — moved aside"
  fi
  if [ -n "${AGE_KEY_FILE:-}" ]; then
    install_key_from "$AGE_KEY_FILE" && { ok "installed key from $AGE_KEY_FILE"; return; }
    warn "AGE_KEY_FILE=$AGE_KEY_FILE has no valid AGE-SECRET-KEY line"
  fi
  if [ -n "${AGE_KEY_FROM:-}" ]; then
    tmp=$(mktemp)
    if scp -q "$AGE_KEY_FROM:.config/chezmoi/key.txt" "$tmp" 2>/dev/null && install_key_from "$tmp"; then
      rm -f "$tmp"; ok "copied key from $AGE_KEY_FROM"; return
    fi
    rm -f "$tmp"; warn "could not fetch a valid key from $AGE_KEY_FROM"
  fi
  if interactive; then
    printf '  Paste the single AGE-SECRET-KEY-1… line from another host (input hidden),\n' >/dev/tty
    printf '  or press Enter to skip (encrypted files are skipped; add the key later).\n' >/dev/tty
    ask_secret '  key> '
    if [ -n "$REPLY" ]; then
      tmp=$(mktemp); printf '%s\n' "$REPLY" > "$tmp"
      if install_key_from "$tmp"; then rm -f "$tmp"; ok "key installed"; return; fi
      rm -f "$tmp"; warn "that did not contain a valid AGE-SECRET-KEY-1 line (74 chars, no spaces)"
    fi
  fi
  warn "no age key — encrypted files will be skipped. Later: scp other-host:~/.config/chezmoi/key.txt $KEY && chezmoi apply"
}

# ── 4. repo access (the dotfiles repo is private) ────────────────────────────
ssh_github_ok() {   # true if ssh authenticates to GitHub ($1 = extra ssh args, $2 = target, default git@github.com)
  need ssh || return 1
  # shellcheck disable=SC2086
  ssh ${1:-} -o BatchMode=yes -o ConnectTimeout=10 -T "${2:-git@github.com}" 2>&1 | grep -q 'successfully authenticated'
}

seed_known_hosts() {   # TOFU, avoids the interactive host-key prompt (old OpenSSH lacks accept-new)
  need ssh-keyscan || return 0
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  grep -q '^github.com ' "$HOME/.ssh/known_hosts" 2>/dev/null \
    || ssh-keyscan -t ed25519,rsa github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
}

setup_deploy_key() {   # generates a key and waits until it is authorised on the repo
  need ssh-keygen || return 1
  [ -f "$DEPLOY_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "dotfiles-deploy@$(hostname)" -f "$DEPLOY_KEY"
  printf '\n  Authorise this machine to read the private repo. Public key:\n\n    %s\n\n' "$(cat "$DEPLOY_KEY.pub")" >/dev/tty
  printf '  From any machine logged in with gh:\n    gh repo deploy-key add <(echo "%s") -R %s -t "%s"\n' \
    "$(cat "$DEPLOY_KEY.pub")" "$GH_SLUG" "$(hostname)" >/dev/tty
  printf '  (or GitHub → %s → Settings → Deploy keys → Add key)\n\n' "$GH_SLUG" >/dev/tty
  ask '  Press Enter once added (or type "skip"): '
  [ "$REPLY" = skip ] && return 1
  touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  grep -q '^Host github-dotfiles$' "$HOME/.ssh/config" || cat >> "$HOME/.ssh/config" <<CFG

# dotfiles-bootstrap: read-only deploy key for the private dotfiles repo
Host github-dotfiles
  HostName github.com
  User git
  IdentityFile $DEPLOY_KEY
  IdentitiesOnly yes
CFG
  # verify through the dedicated alias, i.e. with exactly the key we just generated
  ssh_github_ok "-F $HOME/.ssh/config" git@github-dotfiles || return 1
  REPO="git@github-dotfiles:$GH_SLUG.git"
}

clone_with_token() {   # one-time HTTPS clone; token goes through GIT_ASKPASS, never argv/disk config
  need git || return 1
  ask_pass=$(mktemp)
  # shellcheck disable=SC2016  # the askpass script must expand $GITHUB_TOKEN itself, at run time
  printf '#!/bin/sh\necho "$GITHUB_TOKEN"\n' > "$ask_pass"; chmod 700 "$ask_pass"
  GIT_ASKPASS="$ask_pass" GIT_TERMINAL_PROMPT=0 \
    git clone -q "https://x-access-token@github.com/$GH_SLUG.git" "$SRC"
  rc=$?; rm -f "$ask_pass"
  # (cd + git, not `git -C`: -C needs git >= 1.8.5)
  [ "$rc" -eq 0 ] && ( cd "$SRC" && git remote set-url origin "git@github.com:$GH_SLUG.git" ) 2>/dev/null
  return "$rc"
}

ensure_repo_access() {
  say "4/6 Repo access"
  if [ -d "$SRC/.git" ]; then ok "source already cloned at $SRC"; return; fi
  if ! is_github_repo; then ok "custom repo $REPO (no GitHub auth needed)"; return; fi
  seed_known_hosts
  if ssh_github_ok; then ok "ssh to github.com works"; return; fi
  if [ -n "${GITHUB_TOKEN:-}" ] && clone_with_token; then
    ok "cloned over https with GITHUB_TOKEN (not stored; origin set to ssh)"
    warn "set up an ssh key or deploy key before 'chezmoi update' (token is not kept)"; return
  fi
  if interactive && setup_deploy_key; then ok "deploy key works; origin will use $REPO"; return; fi
  die "No way to read $GH_SLUG. Provide an ssh key, GITHUB_TOKEN, or add a deploy key, then re-run."
}

# ── 5. init + apply ──────────────────────────────────────────────────────────
run_chezmoi() {   # keep prompts working even when this script itself was piped
  if [ -t 0 ] || ! have_tty; then chezmoi "$@"; else chezmoi "$@" </dev/tty; fi
}

init_apply() {
  say "5/6 chezmoi init --apply (installs packages, shell config, tools — can take a few minutes)"
  flags="--force"
  [ "${BOOTSTRAP_YES:-}" = 1 ] && flags="$flags --promptDefaults"
  # shellcheck disable=SC2086
  if [ -d "$SRC/.git" ]; then
    run_chezmoi init --apply $flags ${CHEZMOI_ARGS:-}
  else
    run_chezmoi init --apply $flags ${CHEZMOI_ARGS:-} "$REPO"
  fi || { warn "chezmoi init --apply reported errors — re-run this script, or 'chezmoi apply' to retry"; return 0; }
  # Hosts with an old system git get a git shim from the first apply; a second init writes it into the config.
  if [ -x "$BIN/chezmoi-git" ]; then run_chezmoi init --promptDefaults >/dev/null 2>&1 || true; fi
  ok "dotfiles applied"
}

# ── 6. summary ───────────────────────────────────────────────────────────────
summary() {
  say "6/6 Done"
  if [ -n "$WARNINGS" ]; then printf '\033[33mNeeds attention:\033[0m\n%s' "$WARNINGS"; fi
  printf '\nNext steps:\n'
  printf '  exec zsh -l                      # enter the configured shell\n'
  printf '  chezmoi doctor                   # health check\n'
  printf '  czu  (= chezmoi update)          # pull + apply later changes\n'
  printf '  echo btop >> ~/.config/chezmoi-bootstrap/optional-packages.list && chezmoi apply   # optional extras (btop, ncdu, …)\n\n'
}

main() {
  preflight
  ensure_chezmoi
  ensure_age_key
  ensure_repo_access
  init_apply
  summary
}

# `BOOTSTRAP_SOURCE_ONLY=1 . bootstrap.sh` loads the functions without running (used by tests).
[ "${BOOTSTRAP_SOURCE_ONLY:-}" = 1 ] || main "$@"
