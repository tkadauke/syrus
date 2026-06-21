#!/usr/bin/env bash
# Install Syrus on this Mac. Two ways to run it:
#
#   --docker       Pull the prebuilt image (ghcr.io/tkadauke/syrus-local) and
#                  start web + worker with Compose. Nothing compiles. Installs and
#                  launches OrbStack automatically if no container runtime is
#                  present (prefers an existing Docker Desktop/Colima).
#
#   --bare-metal   Install the toolchain from source on macOS: Xcode CLT,
#                  Homebrew, deps, the Claude CLI, rbenv + Ruby 3.2.3, bin/setup,
#                  and the `syrus` CLI on your PATH. Run from inside a clone.
#                  Add --start to launch the app after.
#
# With no mode flag, the script asks. Both paths are idempotent — safe to re-run.
# Either way, the in-app first-run wizard handles GitHub/agent/repo credentials.
#
#   --start        (bare-metal only) launch `bin/dev` + open the browser at the end
#   --help         show this message
set -euo pipefail
cd "$(dirname "$0")"   # the script lives at the repo root

step() { printf '\n\033[1;34m== %s\033[0m\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf '\033[1;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# Persist a line to a shell rc file only if it's not already there.
persist() { # persist <file> <line>
  local file="$1" line="$2"
  touch "$file"
  grep -qF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

# Ensure Homebrew is installed and on PATH; sets global $BREW. Both paths use it.
ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    info "Homebrew already installed."
  else
    info "installing Homebrew (may prompt for your password)…"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew   # Apple Silicon
  elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew        # Intel
  else die "Homebrew install did not produce a brew binary."; fi
  eval "$("$BREW" shellenv)"
  persist "$HOME/.zprofile" "eval \"\$($BREW shellenv)\""
}

# Launch whichever container runtime is installed (no-op if none — caller handles).
start_docker_runtime() {
  if [ -d "/Applications/OrbStack.app" ]; then
    info "Starting OrbStack…"; open -a OrbStack
  elif [ -d "/Applications/Docker.app" ]; then
    info "Starting Docker Desktop…"; open -a Docker
  elif command -v colima >/dev/null 2>&1; then
    info "Starting Colima…"; colima start
  else
    die "A docker CLI exists but no runtime app to start. Start your runtime and re-run."
  fi
}

# Make sure a container runtime is installed AND its daemon is reachable. On a
# machine with nothing, installs OrbStack (lowest-friction). If a runtime is
# installed but stopped, starts it. Then waits for the daemon. We prefer an
# already-present Docker Desktop/Colima and only install OrbStack when absent.
ensure_docker_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    info "Docker runtime is up."; return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    info "No container runtime found — installing OrbStack…"
    ensure_homebrew
    brew install --cask orbstack
    # OrbStack puts its CLIs here and wires future shells up itself; make `docker`
    # resolvable in THIS run so the pull below works without a new terminal.
    [ -d "$HOME/.orbstack/bin" ] && export PATH="$HOME/.orbstack/bin:$PATH"
    start_docker_runtime
  elif ! docker info >/dev/null 2>&1; then
    info "Docker is installed but its daemon isn't running — starting it…"
    start_docker_runtime
  fi

  info "Waiting for the Docker daemon (first OrbStack launch may ask for a one-time permission)…"
  local tries=0
  until command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 90 ] && die \
      "Docker daemon didn't come up. Open your runtime app, finish any setup prompt, then re-run."
    [ -d "$HOME/.orbstack/bin" ] && export PATH="$HOME/.orbstack/bin:$PATH"
    sleep 2
  done
  info "Docker daemon is up."
}

MODE=""
START_AFTER=0
for arg in "$@"; do
  case "$arg" in
    --docker)            MODE=docker ;;
    --bare-metal|--bare) MODE=bare-metal ;;
    --start)             START_AFTER=1 ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) die "Unknown flag: $arg (try --help)" ;;
  esac
done

# Ask when no mode was given.
if [ -z "$MODE" ]; then
  if [ -t 0 ]; then
    echo "How should Syrus run on this machine?"
    echo "  1) Docker      — pull a prebuilt image; nothing compiles (needs OrbStack/Docker Desktop)"
    echo "  2) Bare metal  — install Ruby/Node/Go via Homebrew and run from source"
    read -r -p "Choose [1/2]: " choice
    case "$choice" in
      1) MODE=docker ;;
      2) MODE=bare-metal ;;
      *) die "Invalid choice: '$choice'. Pass --docker or --bare-metal." ;;
    esac
  else
    die "No mode given and not an interactive shell. Pass --docker or --bare-metal."
  fi
fi

# ===========================================================================
run_docker() {
  if [ "$START_AFTER" = "1" ]; then
    info "(--start is ignored for --docker; the Compose stack always starts.)"
  fi
  IMAGE="${SYRUS_IMAGE:-ghcr.io/tkadauke/syrus-local:latest}"
  export SYRUS_IMAGE="$IMAGE"

  # 1. Make sure a container runtime is installed and running (installs OrbStack
  #    if the machine has nothing; starts an existing/stopped runtime otherwise).
  step "Container runtime"
  ensure_docker_runtime

  # 2. Resolve the Compose command (OrbStack ships the v2 plugin; Colima may need
  #    'brew install docker-compose').
  if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
  elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
  else
    die "Docker Compose not found. Install it (OrbStack bundles it): brew install docker-compose"
  fi

  # 3. Generate .env with fresh secrets on first run.
  if [ ! -f .env ]; then
    step "Generating .env with fresh secrets"
    gen() { openssl rand -hex "$1"; }
    sed \
      -e "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(gen 64)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(gen 32)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*|ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(gen 32)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(gen 32)|" \
      compose.env.example > .env
    info "Wrote .env (keep it safe — it holds your instance secrets)."
  fi

  # 4. Pull the prebuilt image. The daemon is already known reachable, so a
  #    failure here is about the image itself — surface the real error.
  step "Pulling $IMAGE"
  if ! compose pull; then
    echo >&2
    echo "Couldn't pull $IMAGE. See the error above. Common causes:" >&2
    echo "  - The package is private and you're not logged in. Log in once:" >&2
    echo "      echo <YOUR_PAT_with_read:packages> | docker login ghcr.io -u <your-username> --password-stdin" >&2
    echo "    (you must be a collaborator on the package)" >&2
    echo "  - No network, or the tag doesn't exist." >&2
    echo "Then re-run ./install.sh --docker." >&2
    exit 1
  fi

  # 5. Start the stack.
  step "Starting Syrus"
  compose up -d
  port="$(grep -E '^SYRUS_PORT=' .env | cut -d= -f2)"
  echo
  info "Syrus is running at http://localhost:${port:-3000}"
  info "Next steps:"
  info "  1. Open http://localhost:${port:-3000} and create the first admin account."
  info "  2. Complete /onboarding: GitHub credentials, agent, first repository."
  info "  3. Logs: docker compose logs -f web worker   Stop: docker compose down"
  info "  4. Read README.md or website docs for next steps."
}

# ===========================================================================
run_bare_metal() {
  [ "$(uname -s)" = "Darwin" ] || die \
    "--bare-metal is for macOS. On other OSes use --docker."

  step "1/7  Xcode Command Line Tools (compiler, make, git)"
  if xcode-select -p >/dev/null 2>&1; then
    info "already installed."
  else
    info "installing — accept the GUI prompt that appears…"
    xcode-select --install || true
    until xcode-select -p >/dev/null 2>&1; do
      info "waiting for the Command Line Tools install to finish…"
      sleep 15
    done
    info "done."
  fi

  step "2/7  Homebrew"
  ensure_homebrew

  step "3/7  System dependencies via Homebrew"
  # rbenv/ruby-build: Ruby. node: JS + the Claude CLI. go: the Syrus CLI.
  # vips: image processing. mysql: client libs so mysql2 compiles. git/gh: source.
  # openssl@3/readline/libyaml: libs the Ruby build links against.
  brew install rbenv ruby-build node go vips mysql git gh openssl@3 readline libyaml

  step "4/7  Claude Code CLI (the worker shells out to \`claude\`)"
  if command -v claude >/dev/null 2>&1; then
    info "already installed."
  else
    npm install -g @anthropic-ai/claude-code
  fi

  step "5/7  Ruby 3.2.3 via rbenv"
  persist "$HOME/.zshrc" 'eval "$(rbenv init - zsh)"'   # future interactive shells
  eval "$(rbenv init - bash)"                           # this script's shell
  if rbenv versions --bare | grep -qx 3.2.3; then
    info "Ruby 3.2.3 already installed."
  else
    info "compiling Ruby 3.2.3 — this takes a few minutes…"
    rbenv install 3.2.3 --skip-existing
  fi
  rbenv rehash
  # Set a global only if the user has none ("system"), so plain `ruby` works
  # outside the repo too. The repo's .ruby-version pins 3.2.3 inside the checkout
  # regardless, which is what bin/setup relies on.
  [ "$(rbenv global)" = "system" ] && rbenv global 3.2.3 || true

  step "6/7  Confirming the Syrus checkout & active Ruby"
  [ -f bin/setup ] && [ -f .ruby-version ] || die \
    "Run this from a Syrus clone (git clone git@github.com:tkadauke/syrus.git, then ./install.sh --bare-metal)."
  info "checkout: $(pwd)"
  # In the checkout, .ruby-version selects 3.2.3 — verify it.
  ruby_v="$(ruby -v 2>/dev/null || true)"
  case "$ruby_v" in
    *3.2.3*) info "active Ruby: $ruby_v" ;;
    *) die "expected Ruby 3.2.3 but got: ${ruby_v:-none}. Open a new terminal and re-run." ;;
  esac

  step "7/7  bin/setup  (gems, JS deps, Syrus CLI, SQLite databases)"
  # Install the `syrus` CLI into Homebrew's prefix bin. That dir is already on
  # PATH (we ran `brew shellenv`) and is user-writable, so this needs NO extra
  # sudo — unlike bin/setup's default PREFIX=/usr/local, which on Apple Silicon
  # is root-owned and would trigger a second password prompt.
  local brew_prefix; brew_prefix="$("$BREW" --prefix)"
  PREFIX="$brew_prefix" bin/setup --install-cli
  info "Installed the 'syrus' CLI to $brew_prefix/bin/syrus (on your PATH)."

  step "Done."
  info "Syrus is installed, and the 'syrus' CLI is on your PATH (run: syrus --help)."
  info "The first account you create becomes the admin, and the first-run wizard"
  info "handles GitHub credentials, the agent, and a repo."
  if [ "$START_AFTER" = "1" ]; then
    info "Starting the app — opening http://localhost:3000 shortly…"
    ( sleep 8; open http://localhost:3000 >/dev/null 2>&1 || true ) &
    exec bin/dev
  else
    echo
    info "Start it whenever you're ready:"
    info "  bin/dev      # then open http://localhost:3000"
  fi
}

case "$MODE" in
  docker)     run_docker ;;
  bare-metal) run_bare_metal ;;
esac
