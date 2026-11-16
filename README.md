# dotfiles-bootstrap

One command to set up a **new machine** with my [chezmoi](https://www.chezmoi.io) dotfiles
(`Troublesis/dotfiles`, a *private* repo). This repo is public on purpose and contains **no
secrets** — only `bootstrap.sh`, which is what lets a fresh box fetch the private repo.

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Troublesis/dotfiles-bootstrap/main/bootstrap.sh)"
```

Use that form (not `curl | sh`) so your terminal stays attached for the prompts.
Works on macOS and Linux (x86_64 / aarch64), including old distros such as CentOS / Oracle
Linux 7 (glibc 2.17, git 1.8, zsh 5.0). Windows: see `setup.ps1` in the dotfiles repo.
Safe to re-run — each phase skips what is already done.

## What it does

| # | Phase | Detail |
|---|-------|--------|
| 1 | Preflight | OS/arch, needs `curl` + `tar`, puts `~/.local/bin` on PATH |
| 2 | chezmoi | existing → brew (macOS) → `get.chezmoi.io` → static **musl** build (old glibc) |
| 3 | Age key | validates `AGE-SECRET-KEY-1…`; installs from `AGE_KEY_FILE` / `AGE_KEY_FROM` / hidden paste prompt; a malformed key is moved aside, never used |
| 4 | Repo access | ssh to GitHub works → use it; else `GITHUB_TOKEN` one-time https clone; else generates a **read-only deploy key** and waits while you authorise it |
| 5 | `chezmoi init --apply` | installs packages, shell, tmux, tools (see the dotfiles README) |
| 6 | Summary | what still needs attention + next steps |

Without an age key the encrypted files (`~/.zsh_secrets`, tokens, ssh keys) are skipped and
everything else still installs; add the key later and run `chezmoi apply`.

## Options (environment variables)

| Variable | Purpose |
|----------|---------|
| `AGE_KEY_FROM=user@host` | `scp` the key from a host that has it (`~/.config/chezmoi/key.txt`) |
| `AGE_KEY_FILE=/path/key.txt` | install a key you already copied over |
| `GITHUB_TOKEN=…` | fine-grained PAT, **Contents: read** on `Troublesis/dotfiles`; used once via `GIT_ASKPASS`, never written to disk or argv |
| `DOTFILES_REPO=…` | clone something else (default `git@github.com:Troublesis/dotfiles.git`) |
| `CHEZMOI_ARGS=…` | extra args for `chezmoi init --apply` (e.g. `--exclude=scripts`) |
| `BOOTSTRAP_YES=1` | no prompts; chezmoi uses its defaults, key/deploy-key prompts are skipped |

Examples:

```sh
# bring the key along from an existing machine
AGE_KEY_FROM=me@mac-studio sh -c "$(curl -fsSL https://raw.githubusercontent.com/Troublesis/dotfiles-bootstrap/main/bootstrap.sh)"

# headless box with only a token
GITHUB_TOKEN=github_pat_… BOOTSTRAP_YES=1 sh -c "$(curl -fsSL https://raw.githubusercontent.com/Troublesis/dotfiles-bootstrap/main/bootstrap.sh)"
```

## Authorising a deploy key

When no ssh access exists the script prints the machine's new public key. Add it from any
machine logged in with `gh`:

```sh
gh repo deploy-key add key.pub -R Troublesis/dotfiles -t "$(hostname)"
```

The key is read-only, scoped to that single repo, and used through an ssh alias
(`github-dotfiles`) so it does not touch your other GitHub ssh access.

## After it finishes

```sh
exec zsh -l     # enter the configured shell
czu             # chezmoi update (pull + apply) from now on
# optional extras, no root needed:
echo btop >> ~/.config/chezmoi-bootstrap/optional-packages.list && chezmoi apply
```
