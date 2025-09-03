#!/usr/bin/env bash
set -euo pipefail

# ---- helper functions (English comments) ----
msg()  { printf "\033[1;34m[*]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[×]\033[0m %s\n" "$*"; }

require_root() {
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    if [ "$(id -u)" -ne 0 ]; then
      err "This script requires root privileges. Install 'sudo' or run as root."
      exit 1
    fi
    SUDO=""
  fi
}

# Append a line to system-wide and per-user profiles (so PATH/env persist)
add_profile_line() {
  local LINE="$1"
  if [ -w /etc/profile.d ] || $SUDO test -d /etc/profile.d 2>/dev/null; then
    $SUDO bash -c 'touch /etc/profile.d/recontee.sh'
    if ! $SUDO grep -qxF "$LINE" /etc/profile.d/recontee.sh 2>/dev/null; then
      echo "$LINE" | $SUDO tee -a /etc/profile.d/recontee.sh >/dev/null
    fi
  fi
  touch "$HOME/.bashrc"
  if ! grep -qxF "$LINE" "$HOME/.bashrc" 2>/dev/null; then
    echo "$LINE" >> "$HOME/.bashrc"
  fi
}

# ---- detect package manager ----
PKG=""
if   command -v apt   >/dev/null 2>&1; then PKG="apt"
elif command -v dnf   >/dev/null 2>&1; then PKG="dnf"
elif command -v pacman>/dev/null 2>&1; then PKG="pacman"
elif command -v zypper>/dev/null 2>&1; then PKG="zypper"
elif command -v apk   >/dev/null 2>&1; then PKG="apk"
else
  err "Unsupported package manager. Supported: apt, dnf, pacman, zypper, apk."
  exit 1
fi

require_root

# ---- install base packages ----
msg "Installing base system packages..."
case "$PKG" in
  apt)
    $SUDO apt update
    $SUDO DEBIAN_FRONTEND=noninteractive apt install -y       ca-certificates curl jq git build-essential pkg-config       python3 python3-venv python3-pip python3-dev       libpcap-dev
    ;;
  dnf)
    $SUDO dnf install -y curl jq git gcc gcc-c++ make pkgconfig       python3 python3-pip python3-virtualenv python3-devel       libpcap-devel
    ;;
  pacman)
    $SUDO pacman -Sy --noconfirm curl jq git base-devel       python python-pip
    ;;
  zypper)
    $SUDO zypper --non-interactive install curl jq git gcc gcc-c++ make       python3 python3-pip python3-devel libcap-progs libpcap-devel ||       $SUDO zypper --non-interactive install curl jq git gcc gcc-c++ make       python3 python3-pip python3-devel libpcap-devel
    ;;
  apk)
    $SUDO apk add --no-cache curl jq git build-base       python3 py3-pip py3-virtualenv libpcap-dev
    ;;
esac
ok "Base packages installed."

# ---- install Go toolchain (official tarball if absent) ----
if command -v go >/dev/null 2>&1; then
  warn "Go is already installed: $(go version)"
else
  msg "Installing Go (official tarball) into /usr/local/go ..."
  GO_VERSION="${GO_VERSION:-1.22.5}"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) GO_ARCH="amd64" ;;
    aarch64|arm64) GO_ARCH="arm64" ;;
    armv7l) GO_ARCH="armv6l" ;; # best effort
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  URL="https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  TMP=$(mktemp -d)
  curl -fsSL "$URL" -o "$TMP/go.tgz"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "$TMP/go.tgz"
  rm -rf "$TMP"
  ok "Go $GO_VERSION installed."
fi

# Ensure PATH for Go and user/go bin
add_profile_line 'export PATH="/usr/local/go/bin:$PATH"'
add_profile_line 'export PATH="$HOME/go/bin:$PATH"'
# Make it available right now in this shell too
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# ---- install Go-based recon tools ----
msg "Installing reconnaissance tools (Go)..."
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install -v github.com/owasp-amass/amass/v4/...@latest
go install -v github.com/projectdiscovery/dnsx/cmd/dnsx@latest
go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest
go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
go install -v github.com/projectdiscovery/katana/cmd/katana@latest
go install -v github.com/lc/gau/v2/cmd/gau@latest
go install -v github.com/tomnomnom/httprobe@latest
go install -v github.com/ffuf/ffuf/v2@latest
ok "Recon tools installed."

# ---- install Poetry and set env to avoid keyring / interaction ----
msg "Installing Poetry (Python dependency manager)..."
if ! command -v poetry >/dev/null 2>&1; then
  curl -fsSL https://install.python-poetry.org | python3 -
  add_profile_line 'export PATH="$HOME/.local/bin:$PATH"'
fi

# Disable keyring for headless servers & make Poetry non-interactive
add_profile_line 'export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring'
add_profile_line 'export POETRY_NO_INTERACTION=1'
add_profile_line 'export POETRY_VIRTUALENVS_IN_PROJECT=true'
# Apply for current shell too
export PATH="$HOME/.local/bin:$PATH"
export PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring
export POETRY_NO_INTERACTION=1
export POETRY_VIRTUALENVS_IN_PROJECT=true

ok "Poetry ready."

# ---- sanity check ----
msg "Verifying binaries in PATH..."
for b in subfinder amass dnsx naabu httpx katana gau httprobe ffuf; do
  if ! command -v "$b" >/dev/null 2>&1; then
    warn "Not found in PATH: $b"
  else
    ok "$b -> $(command -v $b)"
  fi
done

cat <<'EONEXT'

==============================================================
Installation complete.

IMPORTANT: Reload your PATH in this shell:
  source ~/.bashrc  ||  source /etc/profile  ||  exec $SHELL -l

Next steps (Poetry):
  poetry install
  poetry run recontee healthcheck

Fallback without Poetry:
  python3 -m venv .venv && source .venv/bin/activate
  pip install -U pip wheel setuptools
  pip install typer==0.12.3 rich==13.7.1 pyyaml==6.0.2
  pip install -e .
  python -m recontee.cli healthcheck

Example run:
  poetry run recontee run example.com     --config config.yaml     --resolvers resolvers.txt     --force     --rl-per-host 10
==============================================================
EONEXT
