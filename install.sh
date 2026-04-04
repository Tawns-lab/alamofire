#!/usr/bin/env bash
set -euo pipefail

# OpenClaw Installer
# Usage: curl -fsSL https://openclaw.ai/install.sh | bash

OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
NODE_MIN_VERSION=18
INSTALL_DIR="${OPENCLAW_INSTALL_DIR:-$HOME/.openclaw}"
BIN_DIR="${OPENCLAW_BIN_DIR:-$HOME/.local/bin}"

# ── colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { printf "${CYAN}→${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}✔${RESET}  %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET}  %s\n" "$*" >&2; }
error()   { printf "${RED}✖${RESET}  %s\n" "$*" >&2; exit 1; }
banner()  { printf "\n${BOLD}%s${RESET}\n" "$*"; }

# ── helpers ───────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

os_type() {
  case "$(uname -s)" in
    Linux*)  echo linux ;;
    Darwin*) echo macos ;;
    *)       echo unsupported ;;
  esac
}

arch_type() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    arm64|aarch64) echo arm64 ;;
    armv7l)        echo armv7l ;;
    *)             echo unsupported ;;
  esac
}

node_major_version() {
  node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0
}

add_to_path() {
  local dir="$1"
  local shell_rc=""

  if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
    shell_rc="$HOME/.zshrc"
  elif [ -n "${BASH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "bash" ]; then
    shell_rc="$HOME/.bashrc"
    [ -f "$HOME/.bash_profile" ] && shell_rc="$HOME/.bash_profile"
  fi

  if [ -n "$shell_rc" ]; then
    if ! grep -q "$dir" "$shell_rc" 2>/dev/null; then
      printf '\n# OpenClaw\nexport PATH="%s:$PATH"\n' "$dir" >> "$shell_rc"
    fi
  fi

  export PATH="$dir:$PATH"
}

# ── Node.js installation ──────────────────────────────────────────────────────
install_node_nvm() {
  info "Installing Node.js via nvm..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install --lts
  nvm use --lts
  success "Node.js $(node --version) installed via nvm"
}

install_node_system() {
  local os
  os="$(os_type)"

  if [ "$os" = "macos" ]; then
    if command_exists brew; then
      info "Installing Node.js via Homebrew..."
      brew install node
    else
      error "Homebrew not found. Install it from https://brew.sh then re-run this installer."
    fi
  elif [ "$os" = "linux" ]; then
    if command_exists apt-get; then
      info "Installing Node.js via apt..."
      curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
      sudo apt-get install -y nodejs
    elif command_exists dnf; then
      info "Installing Node.js via dnf..."
      sudo dnf module install -y nodejs:lts/default
    elif command_exists yum; then
      info "Installing Node.js via yum..."
      curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
      sudo yum install -y nodejs
    elif command_exists pacman; then
      info "Installing Node.js via pacman..."
      sudo pacman -S --noconfirm nodejs npm
    else
      error "Could not detect a supported package manager. Please install Node.js $NODE_MIN_VERSION+ manually: https://nodejs.org"
    fi
  else
    error "Unsupported OS. Please install Node.js $NODE_MIN_VERSION+ manually: https://nodejs.org"
  fi
}

ensure_node() {
  local ver
  ver="$(node_major_version)"

  if [ "$ver" -ge "$NODE_MIN_VERSION" ] 2>/dev/null; then
    success "Node.js $(node --version) detected"
    return 0
  fi

  warn "Node.js $NODE_MIN_VERSION+ is required (found: ${ver:-none})"

  if command_exists nvm || [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ] && . "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    nvm install --lts && nvm use --lts
  else
    # Prefer nvm for user-space installs; fall back to system package manager
    if command_exists curl || command_exists wget; then
      install_node_nvm
    else
      install_node_system
    fi
  fi

  ver="$(node_major_version)"
  [ "$ver" -ge "$NODE_MIN_VERSION" ] || error "Node.js installation failed. Please install Node.js $NODE_MIN_VERSION+ manually."
}

# ── OpenClaw CLI installation ─────────────────────────────────────────────────
install_openclaw_npm() {
  info "Installing OpenClaw CLI from npm..."
  if npm install -g "openclaw@$OPENCLAW_VERSION" --quiet 2>/dev/null; then
    return 0
  fi
  # Retry with sudo if permission error
  warn "Global npm install failed (permission issue). Retrying with sudo..."
  sudo npm install -g "openclaw@$OPENCLAW_VERSION" --quiet
}

install_openclaw_local() {
  # Fallback: install into INSTALL_DIR and symlink into BIN_DIR
  info "Installing OpenClaw CLI to $INSTALL_DIR..."
  mkdir -p "$INSTALL_DIR" "$BIN_DIR"

  (
    cd "$INSTALL_DIR"
    npm init -y --quiet >/dev/null
    npm install "openclaw@$OPENCLAW_VERSION" --quiet
  )

  local bin_src="$INSTALL_DIR/node_modules/.bin/openclaw"
  local bin_dst="$BIN_DIR/openclaw"

  if [ -f "$bin_src" ]; then
    ln -sf "$bin_src" "$bin_dst"
    add_to_path "$BIN_DIR"
    success "OpenClaw installed to $bin_dst"
  else
    error "Installation artifact not found at $bin_src. Please report this at https://openclaw.ai/issues"
  fi
}

# ── verify ────────────────────────────────────────────────────────────────────
verify_install() {
  if command_exists openclaw; then
    success "OpenClaw $(openclaw --version 2>/dev/null || echo '') is ready"
    return 0
  fi
  # Check local bin dir added to PATH in same shell
  if [ -x "$BIN_DIR/openclaw" ]; then
    success "OpenClaw installed to $BIN_DIR/openclaw"
    return 0
  fi
  error "OpenClaw command not found after install. Try opening a new terminal and running 'openclaw'."
}

# ── onboarding wizard ─────────────────────────────────────────────────────────
run_onboarding() {
  banner "Launching OpenClaw setup wizard..."
  echo ""

  if command_exists openclaw; then
    openclaw setup
  elif [ -x "$BIN_DIR/openclaw" ]; then
    "$BIN_DIR/openclaw" setup
  else
    warn "Could not launch the onboarding wizard automatically."
    echo "  Run ${BOLD}openclaw setup${RESET} in a new terminal to complete setup."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  local os arch
  os="$(os_type)"
  arch="$(arch_type)"

  [ "$os" = "unsupported" ]   && error "Unsupported OS: $(uname -s)"
  [ "$arch" = "unsupported" ] && error "Unsupported architecture: $(uname -m)"

  printf "\n"
  printf "${BOLD}  ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗${RESET}\n"
  printf "${BOLD} ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║${RESET}\n"
  printf "${BOLD} ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║${RESET}\n"
  printf "${BOLD} ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║${RESET}\n"
  printf "${BOLD} ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝${RESET}\n"
  printf "${BOLD}  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ${RESET}\n"
  printf "\n"
  printf "  Your personal AI assistant — WhatsApp · Telegram · Email · Calendar\n"
  printf "  https://openclaw.ai\n\n"

  banner "Step 1/3 — Checking system requirements"
  info "OS: $os  |  Arch: $arch"
  ensure_node

  banner "Step 2/3 — Installing OpenClaw CLI"
  if npm install -g "openclaw@$OPENCLAW_VERSION" --quiet 2>/dev/null; then
    success "OpenClaw installed via npm"
  else
    install_openclaw_local
  fi

  banner "Step 3/3 — Verifying installation"
  verify_install

  echo ""
  success "Installation complete!"
  echo ""
  echo "  ${BOLD}What's next?${RESET}"
  echo "  The setup wizard will guide you through:"
  echo "   • Connecting WhatsApp, Telegram, or SMS"
  echo "   • Linking your email account(s)"
  echo "   • Syncing your calendar"
  echo "   • Setting your preferences & AI persona"
  echo ""

  run_onboarding
}

main "$@"
