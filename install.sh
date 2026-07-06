#!/usr/bin/env bash
# Install Syrus on this Mac. Two ways to run it:
#
#   --docker       Pull the prebuilt image (ghcr.io/tkadauke/syrus-backend) and
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
#
# Docker-mode flags for driving this script from a GUI (the desktop app):
#
#   --non-interactive       never prompt; a missing decision is an error (exit 2)
#   --json                  machine-readable NDJSON events on stdout (start, step,
#                           log, error, done); human-readable output moves to stderr
#   --target-dir DIR        directory that owns mutable state: .env and a synced
#                           copy of docker-compose.yml; Compose runs from there.
#                           Default: this script's own directory (the clone).
#   --skip-runtime-install  never install Homebrew/OrbStack; exit 10 if no
#                           container runtime exists, 11 if the daemon won't start
#   --image REF             pin SYRUS_IMAGE; persisted into .env so later plain
#                           `docker compose up` runs use the same tag
#   --port N                first install only: serve on this port instead of 3000
#
# Exit codes: 0 ok · 2 usage · 10 no runtime (with --skip-runtime-install) ·
# 11 daemon never became ready · 12 no compose · 20 data volume exists but .env
# is missing (encryption-key guard) · 30 image pull failed (network/other) ·
# 31 image pull denied (private package / unpublished tag / not logged in) ·
# 32 image tag not found in the registry · 40 compose up failed · 41 health
# check timed out · 1 anything else
set -euo pipefail
cd "$(dirname "$0")"   # the script lives at the repo root (or the app's Resources)
ASSETS_DIR="$PWD"      # read-only home of docker-compose.yml + compose.env.example

# GUI-launched processes don't inherit a login-shell PATH; make the usual
# docker/orbstack install locations searchable no matter who spawned us.
for p in "$HOME/.orbstack/bin" /opt/homebrew/bin /usr/local/bin \
         "/Applications/Docker.app/Contents/Resources/bin"; do
  if [ -d "$p" ]; then
    case ":$PATH:" in *":$p:"*) ;; *) PATH="$PATH:$p" ;; esac
  fi
done
export PATH

JSON=0
CURRENT_STEP=""

# In --json mode, stdout carries exactly one JSON event per line and all
# human-readable output moves to stderr, so a GUI can parse the stream.
step() {
  if [ "$JSON" = "1" ]; then printf '\n== %s\n' "$1" >&2
  else printf '\n\033[1;34m== %s\033[0m\n' "$1"; fi
}
info() {
  if [ "$JSON" = "1" ]; then printf '   %s\n' "$1" >&2
  else printf '   %s\n' "$1"; fi
}

json_escape() { # produce valid RFC 8259 string content from arbitrary text
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  # Remaining C0 control bytes (ANSI ESC from tool output, etc.) would make
  # the JSON unparseable for the GUI driver — strip them.
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '%s' "$s"
}
emit() { [ "$JSON" = "1" ] && printf '%s\n' "$1"; return 0; }
emit_step() { # emit_step <id> <status> [detail] — also tracks context for die()
  CURRENT_STEP="$1"
  local extra=""
  [ -n "${3:-}" ] && extra=",\"detail\":\"$(json_escape "$3")\""
  emit "{\"event\":\"step\",\"id\":\"$1\",\"status\":\"$2\"$extra}"
}
emit_log() { emit "{\"event\":\"log\",\"stream\":\"$1\",\"line\":\"$(json_escape "$2")\"}"; }

die() { # die <message> [exit-code]
  local code="${2:-1}"
  emit "{\"event\":\"error\",\"code\":$code,\"step\":\"$(json_escape "$CURRENT_STEP")\",\"message\":\"$(json_escape "$1")\"}"
  printf '\033[1;31mError: %s\033[0m\n' "$1" >&2
  exit "$code"
}

run_logged() { # run_logged <stream> <cmd…> — stream child output as log events in --json mode
  local stream="$1"; shift
  if [ "$JSON" = "1" ]; then
    "$@" 2>&1 | while IFS= read -r line; do emit_log "$stream" "$line"; done
  else
    "$@"
  fi
}

run_logged_captured() { # run_logged_captured <capture-file> <stream> <cmd…> — run_logged that also tees output for failure classification
  local capture="$1" stream="$2"; shift 2
  if [ "$JSON" = "1" ]; then
    "$@" 2>&1 | tee "$capture" | while IFS= read -r line; do emit_log "$stream" "$line"; done
  else
    "$@" 2>&1 | tee "$capture"
  fi
}

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
    die "A docker CLI exists but no runtime app to start. Start your runtime and re-run." 11
  fi
}

# Make sure a container runtime is installed AND its daemon is reachable. On a
# machine with nothing, installs OrbStack (lowest-friction). If a runtime is
# installed but stopped, starts it. Then waits for the daemon. We prefer an
# already-present Docker Desktop/Colima and only install OrbStack when absent.
# With --skip-runtime-install we never install anything (the GUI owns runtime
# acquisition) but still start an installed-but-stopped runtime.
ensure_docker_runtime() {
  emit_step runtime_check start
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    info "Docker runtime is up."
    emit_step runtime_check ok
    # The GUI ensures the daemon is up before spawning us, so this is the
    # common path — resolve the start step so its checklist row never
    # dangles as pending.
    emit_step runtime_start skipped
    return 0
  fi
  emit_step runtime_check ok "runtime not ready yet"

  if ! command -v docker >/dev/null 2>&1 \
     && [ ! -d /Applications/OrbStack.app ] && [ ! -d /Applications/Docker.app ] \
     && ! command -v colima >/dev/null 2>&1; then
    if [ "$SKIP_RUNTIME_INSTALL" = "1" ]; then
      emit_step runtime_install start
      die "No container runtime found. Install OrbStack (https://orbstack.dev) or Docker Desktop, then retry." 10
    fi
    emit_step runtime_install start
    info "No container runtime found — installing OrbStack…"
    ensure_homebrew
    brew install --cask orbstack
    # OrbStack puts its CLIs here and wires future shells up itself; make `docker`
    # resolvable in THIS run so the pull below works without a new terminal.
    [ -d "$HOME/.orbstack/bin" ] && export PATH="$HOME/.orbstack/bin:$PATH"
    emit_step runtime_install ok
    start_docker_runtime
  elif ! docker info >/dev/null 2>&1; then
    info "A container runtime is installed but not running — starting it…"
    start_docker_runtime
  fi

  emit_step runtime_start start
  info "Waiting for the Docker daemon (first OrbStack launch may ask for a one-time permission)…"
  local tries=0
  until command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -gt 90 ] && die \
      "Docker daemon didn't come up. Open your runtime app, finish any setup prompt, then re-run." 11
    [ -d "$HOME/.orbstack/bin" ] && export PATH="$HOME/.orbstack/bin:$PATH"
    sleep 2
  done
  info "Docker daemon is up."
  emit_step runtime_start ok
}

MODE=""
START_AFTER=0
NON_INTERACTIVE=0
SKIP_RUNTIME_INSTALL=0
TARGET_DIR=""
IMAGE_OVERRIDE=""
PORT_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --docker)               MODE=docker ;;
    --bare-metal|--bare)    MODE=bare-metal ;;
    --start)                START_AFTER=1 ;;
    --non-interactive)      NON_INTERACTIVE=1 ;;
    --json)                 JSON=1 ;;
    --skip-runtime-install) SKIP_RUNTIME_INSTALL=1 ;;
    --target-dir)
      [ $# -ge 2 ] || die "--target-dir needs a path" 2
      TARGET_DIR="$2"; shift ;;
    --image)
      [ $# -ge 2 ] || die "--image needs an image reference" 2
      # Validated because the value is spliced into a sed replacement below;
      # docker references never contain sed metacharacters anyway.
      case "$2" in ''|*[!A-Za-z0-9._/:@-]*) die "--image must be a plain image reference, got: $2" 2 ;; esac
      IMAGE_OVERRIDE="$2"; shift ;;
    --port)
      [ $# -ge 2 ] || die "--port needs a number" 2
      case "$2" in ''|*[!0-9]*) die "--port must be a number, got: $2" 2 ;; esac
      PORT_OVERRIDE="$2"; shift ;;
    --help|-h) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) die "Unknown flag: $1 (try --help)" 2 ;;
  esac
  shift
done

# Ask when no mode was given.
if [ -z "$MODE" ]; then
  if [ "$NON_INTERACTIVE" = "1" ]; then
    die "No mode given. Pass --docker or --bare-metal." 2
  elif [ -t 0 ]; then
    echo "How should Syrus run on this machine?"
    echo "  1) Docker      — pull a prebuilt image; nothing compiles (needs OrbStack/Docker Desktop)"
    echo "  2) Bare metal  — install Ruby/Node/Go via Homebrew and run from source"
    read -r -p "Choose [1/2]: " choice
    case "$choice" in
      1) MODE=docker ;;
      2) MODE=bare-metal ;;
      *) die "Invalid choice: '$choice'. Pass --docker or --bare-metal." 2 ;;
    esac
  else
    die "No mode given and not an interactive shell. Pass --docker or --bare-metal." 2
  fi
fi

# The GUI flags only make sense for the docker path.
if [ "$MODE" = "bare-metal" ]; then
  if [ "$JSON" = "1" ] || [ -n "$TARGET_DIR" ] || [ "$SKIP_RUNTIME_INSTALL" = "1" ] \
     || [ -n "$IMAGE_OVERRIDE" ] || [ -n "$PORT_OVERRIDE" ]; then
    die "--json/--target-dir/--skip-runtime-install/--image/--port only apply to --docker" 2
  fi
fi

# ===========================================================================
run_docker() {
  if [ "$START_AFTER" = "1" ]; then
    info "(--start is ignored for --docker; the Compose stack always starts.)"
  fi
  IMAGE="${IMAGE_OVERRIDE:-${SYRUS_IMAGE:-ghcr.io/tkadauke/syrus-backend:latest}}"
  export SYRUS_IMAGE="$IMAGE"
  # Belt-and-braces alongside the compose file's `name: syrus`: keeps the
  # `syrus_` volume prefix stable for docker-compose v1 and odd invocation dirs.
  export COMPOSE_PROJECT_NAME=syrus

  # The target dir owns mutable state (.env, a synced copy of docker-compose.yml).
  # Default: the script's own directory — the classic clone workflow. The desktop
  # app passes --target-dir because its bundle is read-only and signature-sealed:
  # writing next to the bundled script would break the code signature.
  if [ -n "$TARGET_DIR" ]; then
    mkdir -p "$TARGET_DIR"
    # Keep the compose file in sync with this installer's version on every run.
    cp -f "$ASSETS_DIR/docker-compose.yml" "$TARGET_DIR/docker-compose.yml"
    cd "$TARGET_DIR"
  fi

  emit "{\"event\":\"start\",\"mode\":\"docker\",\"image\":\"$(json_escape "$IMAGE")\",\"target_dir\":\"$(json_escape "$PWD")\"}"

  # 1. Make sure a container runtime is installed and running (installs OrbStack
  #    if the machine has nothing; starts an existing/stopped runtime otherwise).
  step "Container runtime"
  ensure_docker_runtime

  # 2. Resolve the Compose command (OrbStack ships the v2 plugin; Colima may need
  #    'brew install docker-compose').
  emit_step compose_resolve start
  if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
  elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
  else
    die "Docker Compose not found. Install it (OrbStack bundles it): brew install docker-compose" 12
  fi
  emit_step compose_resolve ok

  # 3. Generate .env with fresh secrets on first run — but NEVER mint fresh
  #    encryption keys when a data volume already exists. The existing DB was
  #    encrypted with the old keys; new keys can't decrypt it and every page
  #    500s with ActiveRecord::Encryption::Errors::Decryption.
  emit_step env_check start
  if [ ! -f .env ] && docker volume inspect syrus_syrus-data >/dev/null 2>&1; then
    echo "Error: a data volume (syrus_syrus-data) exists but .env is missing." >&2
    echo "Its database is encrypted with keys that lived in that .env. Generating" >&2
    echo "fresh keys now would make the existing data undecryptable. Do ONE of:" >&2
    echo "  - Restore the original .env (the keys that match this volume), or" >&2
    echo "  - Wipe the old data and start clean:" >&2
    echo "      docker compose down -v && ./install.sh --docker   (or docker-compose ...)" >&2
    die "a data volume (syrus_syrus-data) exists but .env is missing (see above)" 20
  fi
  emit_step env_check ok

  if [ ! -f .env ]; then
    step "Generating .env with fresh secrets"
    emit_step env_generate start
    gen() { openssl rand -hex "$1"; }
    sed \
      -e "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(gen 64)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(gen 32)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*|ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(gen 32)|" \
      -e "s|^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(gen 32)|" \
      "$ASSETS_DIR/compose.env.example" > .env
    if [ -n "$PORT_OVERRIDE" ]; then
      sed \
        -e "s|^SYRUS_PORT=.*|SYRUS_PORT=$PORT_OVERRIDE|" \
        -e "s|^SYRUS_APP_HOST=.*|SYRUS_APP_HOST=localhost:$PORT_OVERRIDE|" \
        .env > .env.tmp && mv .env.tmp .env
    fi
    info "Wrote .env (keep it safe — it holds your instance secrets)."
    emit_step env_generate ok
  else
    emit_step env_generate skipped
    if [ -n "$PORT_OVERRIDE" ]; then
      info "(--port is ignored: .env already exists and owns the port.)"
    fi
  fi

  # Persist an explicit image pin so later plain `docker compose up` runs (e.g.
  # the desktop app's Start/Stop controls) use the same tag as this install.
  # Unlike --port, this intentionally updates an existing .env — app updates
  # move the pin forward — but never silently: a changed pin is announced.
  if [ -n "$IMAGE_OVERRIDE" ]; then
    if grep -qE '^SYRUS_IMAGE=' .env; then
      current_pin="$(grep -E '^SYRUS_IMAGE=' .env | head -1 | cut -d= -f2-)"
      if [ "$current_pin" != "$IMAGE_OVERRIDE" ]; then
        info "Updating the SYRUS_IMAGE pin: ${current_pin:-<empty>} -> $IMAGE_OVERRIDE"
        emit_log env "SYRUS_IMAGE pin updated: ${current_pin:-<empty>} -> $IMAGE_OVERRIDE"
        sed -e "s|^SYRUS_IMAGE=.*|SYRUS_IMAGE=$IMAGE_OVERRIDE|" .env > .env.tmp && mv .env.tmp .env
      fi
    else
      printf 'SYRUS_IMAGE=%s\n' "$IMAGE_OVERRIDE" >> .env
    fi
  fi

  # 4. Pull the prebuilt image. The daemon is already known reachable, so a
  #    failure here is about the image itself — surface the real error. The
  #    download is large, so a transient network blip (e.g. "tls: bad record
  #    MAC" mid-pull) gets a couple of automatic retries before we give up.
  step "Pulling $IMAGE"
  emit_step image_pull start "$IMAGE"
  pull_ok=0
  pull_log="$(mktemp "${TMPDIR:-/tmp}/syrus-pull.XXXXXX")"
  for pull_attempt in 1 2 3; do
    if run_logged_captured "$pull_log" pull compose pull; then
      pull_ok=1
      break
    fi
    if [ "$pull_attempt" -lt 3 ]; then
      info "Pull failed (attempt $pull_attempt/3) — retrying…"
      emit_log pull "pull attempt $pull_attempt failed; retrying"
      sleep "${SYRUS_PULL_RETRY_DELAY:-5}"
    fi
  done
  # Read-then-delete up front: die() exits, so cleanup placed after the
  # classification would never run on exactly the failure paths that use it.
  pull_error="$(cat "$pull_log" 2>/dev/null || true)"
  rm -f "$pull_log"
  if [ "$pull_ok" != "1" ]; then
    # A locally built or previously pulled copy still works — key for fork
    # iteration (build the image locally, install without any registry) and
    # for offline reinstalls.
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      info "Pull failed, but $IMAGE exists locally — continuing with the local copy."
      emit_log pull "pull failed; using the local image copy"
    else
      # Classify the last attempt so the operator (and the desktop app's
      # error screen, keyed on the exit code) gets the real cause instead of
      # a generic "check your network": 31 = registry refused (private
      # package / unpublished tag / not logged in), 32 = the tag genuinely
      # doesn't exist on a readable package, 30 = network/other.
      echo >&2
      echo "Couldn't pull $IMAGE. See the error above." >&2
      case "$pull_error" in
        # Docker's credential helper choked on a stored (usually stale) login —
        # e.g. "error getting credentials" from a broken keychain entry. Docker
        # sends stored ghcr.io credentials on EVERY pull, and GHCR rejects an
        # expired/revoked token even for public images, so the fix is to log
        # OUT, not in. Checked before the generic denied branch: the helper's
        # message contains neither "denied" nor "unauthorized" and used to
        # misclassify as a network problem (exit 30).
        *"error getting credentials"*|*"credential helper"*|*"credentials store"*)
          echo "Docker has stored login credentials for the registry that it can no longer" >&2
          echo "read (or that have expired). The image is public — no login is needed." >&2
          echo "Clear the stale credentials and retry:" >&2
          echo "    docker logout ghcr.io" >&2
          echo "Then re-run ./install.sh --docker." >&2
          die "stored Docker credentials for the registry are broken — run: docker logout ghcr.io" 31
          ;;
        *[Dd]enied*|*[Uu]nauthorized*|*"authentication required"*|*[Ff]orbidden*)
          echo "The registry refused the download. The most common cause is STALE stored" >&2
          echo "credentials: docker sends any saved ghcr.io login with every pull, and an" >&2
          echo "expired token is rejected even for public images. Clear it and retry:" >&2
          echo "    docker logout ghcr.io" >&2
          echo "If that doesn't help, the package may be private or the tag unpublished —" >&2
          echo "make the package public, or log in with a valid token:" >&2
          echo "    echo <YOUR_PAT_with_read:packages> | docker login ghcr.io -u <your-username> --password-stdin" >&2
          echo "Then re-run ./install.sh --docker." >&2
          die "access to $IMAGE was denied (stale login, private package, or unpublished tag)" 31
          ;;
        *"manifest unknown"*|*"not found"*)
          echo "The package exists but this tag doesn't — the build that produced this" >&2
          echo "installer references an image that was never published." >&2
          die "the image tag $IMAGE does not exist in the registry" 32
          ;;
        *)
          echo "This usually means a network problem. Check your connection and re-run" >&2
          echo "./install.sh --docker." >&2
          die "couldn't pull $IMAGE after 3 attempts" 30
          ;;
      esac
    fi
  fi
  emit_step image_pull ok

  # 5. Start the stack.
  step "Starting Syrus"
  emit_step stack_up start
  run_logged up compose up -d || die "docker compose up failed" 40
  emit_step stack_up ok

  # `|| true`: a hand-written/adopted .env may lack SYRUS_PORT, and under
  # pipefail the failed grep would otherwise kill the whole script here.
  port="$(grep -E '^SYRUS_PORT=' .env | cut -d= -f2 || true)"
  port="${port:-3000}"

  # 6. Wait until the web app actually answers, so success means "usable",
  #    not just "containers created". First boot runs migrations.
  emit_step health start
  info "Waiting for Syrus to answer at http://localhost:${port} …"
  local tries=0
  until curl -fs -o /dev/null "http://localhost:${port}/up" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt "${SYRUS_HEALTH_POLLS:-90}" ] && die \
      "Syrus didn't become healthy within 3 minutes. Check: docker compose logs web worker" 41
    sleep 2
  done
  emit_step health ok
  emit "{\"event\":\"done\",\"url\":\"http://localhost:${port}\"}"

  # In --json mode stdout is protocol-only; the blank spacer line must not
  # leak into the NDJSON stream.
  [ "$JSON" = "1" ] || echo
  info "Syrus is running at http://localhost:${port}"
  info "Next steps:"
  info "  1. Open http://localhost:${port} and create the first admin account."
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
