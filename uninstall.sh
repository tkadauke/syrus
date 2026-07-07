#!/usr/bin/env bash
# Uninstall Syrus from this machine — the reverse of install.sh --docker plus
# the desktop-app artifacts. What it removes:
#
#   - the Docker Compose stack (project `syrus`): containers are found by
#     their compose project label (covers compose v1 underscore and v2
#     hyphen container names alike) and removed by ID; unless --keep-data, the
#     data volumes go too — found by the same label PLUS the known names
#     (syrus_syrus-data, syrus_syrus-search) as a fallback. Teardown is
#     VERIFIED by re-listing afterwards; anything left behind is reported
#     honestly (step status `failed`) and the script exits 3
#   - images whose repository BASENAME is exactly `syrus-backend` or
#     `syrus-local` (any registry/namespace — the same exact-segment
#     semantics as desktop/electron/installer/imageCleanup.ts, so a user's
#     unrelated `my-syrus-backend` never matches). Removal is a plain
#     `docker rmi <repo:tag>` per tag, never -f: -f would untag EVERY tag
#     sharing the image ID (a user's backup tag included). Polite refusals
#     are logged and left in place
#   - ~/.syrus/local — the .env in here holds the DATABASE ENCRYPTION KEYS;
#     it is deleted ONLY once the docker data volumes are verifiably gone.
#     A surviving syrus_syrus-data volume with the keys deleted would wedge
#     any reinstall (install.sh's exit-20 guard) with no compose file left
#     to fix it, so if Docker is unreachable or a volume survives, the
#     directory is KEPT, a warning is emitted, and the script exits 3 —
#     start Docker and re-run to finish. (Skipped by --keep-data.)
#   - ~/.syrus/credentials (skipped by --keep-data), and ~/.syrus itself when
#     it is empty afterward
#   - the `syrus` CLI at ~/.local/bin/syrus
#   - the Claude Code skill at ~/.claude/skills/syrus
#   - the desktop app: ~/Applications/Syrus.app on macOS, plus the bundle
#     named by --app-path when given (the desktop app passes its own
#     location, which may be /Applications/Syrus.app); ~/.local/bin/Syrus on
#     Linux (AppImage locations are user-chosen — delete yours manually)
#   - desktop app settings: ~/Library/Application Support/Syrus on macOS,
#     ~/.config/Syrus on Linux (skipped by --keep-data)
#
# Shared tools are NEVER touched: Docker Desktop / OrbStack / Colima,
# Homebrew, and rbenv have their own uninstallers.
#
# Default is interactive: prints exactly what will be removed and asks one
# y/N question. Flags:
#
#   --yes             skip the confirmation prompt
#   --keep-data       preserve ~/.syrus (encryption keys, credentials), the
#                     docker data volumes, and the app settings; removes only
#                     the app, CLI, skill, containers, and images
#   --json            machine-readable NDJSON events on stdout (start, step,
#                     log, error, done), the same protocol install.sh speaks;
#                     implies --yes (a GUI does its own confirmation)
#   --app-path=PATH   also remove the app bundle at PATH (the desktop app
#                     passes where it is actually running from). PATH must be
#                     absolute, end in /Syrus.app, and resolve (symlinks
#                     followed) to a real path under /Applications or
#                     $HOME/Applications — anything else is warned about and
#                     IGNORED, never removed
#   --help            show this message
#
# Exit codes: 0 ok (including a declined prompt and "nothing left to remove")
# · 2 usage · 3 partial — something could not be removed or verified: Docker
# unreachable, a leftover container/volume after teardown, or a failed file
# removal. Without --keep-data the encryption keys in ~/.syrus/local are kept
# until the data volumes are verifiably gone, so starting Docker and
# re-running finishes the job. On a partial run the NDJSON stream ends with
# an `error` event (code 3) instead of `done` · 1 anything else. Missing
# artifacts are skipped — re-running is always safe.
set -euo pipefail

# GUI-launched processes don't inherit a login-shell PATH; make the usual
# docker install locations searchable no matter who spawned us (same list as
# install.sh).
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

# A failed or unverifiable teardown step must not abort the remaining steps
# and must not be reported as success: each one records a reason here, and
# the script exits 3 (with an error event, code 3, instead of done) at the
# end if anything was recorded.
PARTIAL=0
PARTIAL_REASONS=""
add_partial() { # add_partial <reason>
  PARTIAL=1
  if [ -n "$PARTIAL_REASONS" ]; then PARTIAL_REASONS="$PARTIAL_REASONS; $1"
  else PARTIAL_REASONS="$1"; fi
}

ASSUME_YES=0
KEEP_DATA=0
APP_PATH_ARG=""
APP_PATH_PROVIDED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1 ;;
    --keep-data)  KEEP_DATA=1 ;;
    --json)       JSON=1; ASSUME_YES=1 ;;
    --app-path=*) APP_PATH_PROVIDED=1; APP_PATH_ARG="${1#--app-path=}" ;;
    --app-path)   APP_PATH_PROVIDED=1 ;; # bare form carries no value → warned about and ignored
    --help|-h)    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) die "Unknown flag: $1 (try --help)" 2 ;;
  esac
  shift
done

OS="$(uname -s)"
STATE_DIR="$HOME/.syrus/local"
CREDENTIALS_FILE="$HOME/.syrus/credentials"
CLI_BIN="$HOME/.local/bin/syrus"
SKILL_DIR="$HOME/.claude/skills/syrus"
if [ "$OS" = "Darwin" ]; then
  APP_PATH="$HOME/Applications/Syrus.app"
  SETTINGS_DIR="$HOME/Library/Application Support/Syrus"
else
  APP_PATH="$HOME/.local/bin/Syrus"
  SETTINGS_DIR="$HOME/.config/Syrus"
fi

# Belt-and-braces alongside the compose file's `name: syrus`: keeps the
# `syrus_` volume prefix stable for docker-compose v1 and odd invocation dirs.
export COMPOSE_PROJECT_NAME=syrus
# Compose v1 and v2 both stamp this label on everything they create — it is
# the reliable way to enumerate the stack regardless of container naming
# scheme (v1 `syrus_web_1` underscores vs v2 hyphens).
COMPOSE_LABEL_FILTER="label=com.docker.compose.project=syrus"
KNOWN_VOLUMES="syrus_syrus-data syrus_syrus-search"

docker_ready=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker_ready=1
fi

describe_path() { # "<path> (<size>)" or "<path> (not present)"
  local target="$1" size=""
  if [ -e "$target" ] || [ -L "$target" ]; then
    size="$(du -sh "$target" 2>/dev/null | cut -f1 || true)"
    printf '%s (%s)' "$target" "${size:-present}"
  else
    printf '%s (not present)' "$target"
  fi
}

remove_step() { # remove_step <step-id> <path> <human-label> — guarded rm -rf with events
  # Failure-tolerant on purpose: a failing rm must not abort the remaining
  # teardown under set -e. The path actually being gone afterwards is the
  # only success criterion; anything else is a failed step + partial exit.
  local id="$1" target="$2" label="$3"
  if [ -e "$target" ] || [ -L "$target" ]; then
    emit_step "$id" start
    local rm_output=""
    rm_output="$(rm -rf "$target" 2>&1 || true)"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      info "Removed $label: $target"
      emit_log files "removed $target"
      emit_step "$id" ok
    else
      info "WARNING: could not fully remove $label: $target"
      [ -n "$rm_output" ] && info "         $rm_output"
      emit_log files "failed to remove $target${rm_output:+: $rm_output}"
      emit_step "$id" failed "could not remove $target"
      add_partial "could not remove $target"
    fi
  else
    emit_step "$id" skipped "not present"
  fi
}

canonical_path() { # physical (symlink-resolved) path of an existing file; fails otherwise
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null
    return
  fi
  # Pre-realpath macOS fallback: resolve the parent physically and refuse
  # leaf symlinks (they cannot be resolved portably here — fail closed, the
  # caller warns and ignores).
  local dir base
  dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$target")"
  [ -L "$dir/$base" ] && return 1
  [ -e "$dir/$base" ] || return 1
  printf '%s\n' "$dir/$base"
}

list_syrus_containers() { # every container the compose project ever created, by ID
  docker ps -aq --filter "$COMPOSE_LABEL_FILTER" 2>/dev/null || true
}

list_syrus_volumes() { # label-discovered volumes PLUS the known names, deduped
  {
    docker volume ls -q --filter "$COMPOSE_LABEL_FILTER" 2>/dev/null || true
    local v
    # shellcheck disable=SC2086 # KNOWN_VOLUMES is a fixed space-separated list
    for v in $KNOWN_VOLUMES; do
      if docker volume inspect "$v" >/dev/null 2>&1; then printf '%s\n' "$v"; fi
    done
  } | sort -u | sed '/^$/d'
}

# --app-path validation. The desktop app passes the bundle it is actually
# running from; a GUI bug or a hand-typed value must never turn this script
# into `rm -rf <anything>`. Valid means: absolute, ends in /Syrus.app, and
# resolves (symlinks followed) to a real path under /Applications or
# $HOME/Applications. Anything else: warn and ignore, never remove.
APP_PATH_EXTRA=""
APP_PATH_EXTRA_RESOLVED=""
APP_PATH_STATUS="" # "" (not given) | ok | not_present | duplicate | invalid
if [ "$APP_PATH_PROVIDED" = "1" ]; then
  APP_PATH_STATUS=invalid
  case "$APP_PATH_ARG" in
    /*/Syrus.app)
      if [ ! -e "$APP_PATH_ARG" ] && [ ! -L "$APP_PATH_ARG" ]; then
        # Syntactically fine, nothing there — the removal step will skip it.
        APP_PATH_STATUS=not_present
      else
        resolved="$(canonical_path "$APP_PATH_ARG" || true)"
        home_apps="$(canonical_path "$HOME/Applications" || printf '%s' "$HOME/Applications")"
        if [ -n "$resolved" ]; then
          case "$resolved" in
            /Applications/*|"$home_apps"/*)
              default_resolved="$(canonical_path "$APP_PATH" || printf '%s' "$APP_PATH")"
              if [ "$resolved" = "$default_resolved" ]; then
                APP_PATH_STATUS=duplicate # already covered by the built-in default
              else
                APP_PATH_STATUS=ok
                APP_PATH_EXTRA="$APP_PATH_ARG"
                APP_PATH_EXTRA_RESOLVED="$resolved"
              fi
              ;;
          esac
        fi
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# The plan — printed before anything is touched (stderr in --json mode).
step "Uninstalling Syrus — the plan"
if [ "$docker_ready" = "1" ]; then
  if [ "$KEEP_DATA" = "1" ]; then
    info "Docker: stop and remove the syrus containers (volumes KEPT: --keep-data)"
  else
    info "Docker: remove the syrus containers AND the data volumes (found by"
    info "        compose label; known names syrus_syrus-data, syrus_syrus-search"
    info "        as a fallback) — verified by re-listing after teardown"
  fi
  info "Docker images: syrus-backend and syrus-local images (exact repository"
  info "               basename, any registry) — plain docker rmi per tag, never -f"
else
  info "Docker: not reachable — container/volume/image removal will be SKIPPED."
fi
if [ "$KEEP_DATA" = "1" ]; then
  info "Keeping (--keep-data): $STATE_DIR, $CREDENTIALS_FILE,"
  info "                       $SETTINGS_DIR, and the docker data volumes"
else
  if [ "$docker_ready" = "1" ]; then
    info "DELETE $(describe_path "$STATE_DIR")"
    info "       ⚠ its .env holds the ENCRYPTION KEYS for the Syrus database;"
    info "       together with the data volume this DESTROYS the local Syrus data"
    info "       permanently. Use --keep-data to keep it. Deleted only once the"
    info "       data volumes are verifiably gone."
  else
    info "KEEP   $(describe_path "$STATE_DIR")"
    info "       ⚠ its .env holds the ENCRYPTION KEYS for the data volumes, and"
    info "       Docker is unreachable so the volumes cannot be removed now."
    info "       The keys stay until the volumes are verifiably gone (this run"
    info "       will exit 3 — start Docker and re-run to finish)."
  fi
  info "DELETE $(describe_path "$CREDENTIALS_FILE")"
  info "DELETE $(describe_path "$SETTINGS_DIR")"
fi
info "DELETE $(describe_path "$CLI_BIN")"
info "DELETE $(describe_path "$SKILL_DIR")"
info "DELETE $(describe_path "$APP_PATH")"
case "$APP_PATH_STATUS" in
  ""|duplicate) ;;
  ok|not_present)
    info "DELETE $(describe_path "$APP_PATH_ARG") (--app-path)" ;;
  *)
    info "WARNING: ignoring invalid --app-path: ${APP_PATH_ARG:-<empty>}"
    info "         it must be an absolute path ending in /Syrus.app that resolves"
    info "         under /Applications or $HOME/Applications. Nothing will be"
    info "         removed for it." ;;
esac
if [ "$OS" = "Darwin" ] && [ -d "/Applications/Syrus.app" ] && \
   [ "$APP_PATH_EXTRA_RESOLVED" != "/Applications/Syrus.app" ]; then
  info "Note: /Applications/Syrus.app also exists — this run only removes the"
  info "      paths above; pass --app-path=/Applications/Syrus.app (or drag it"
  info "      to the Trash) to remove that copy."
fi
info "NOT touched: Docker Desktop / OrbStack / Colima, Homebrew, rbenv — shared"
info "tools with their own uninstallers."

if [ "$ASSUME_YES" != "1" ]; then
  if [ ! -t 0 ]; then
    die "Not an interactive shell. Pass --yes (or --json) to confirm removal." 2
  fi
  echo
  read -r -p "Remove Syrus from this machine? [y/N] " answer
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) info "Aborted — nothing was removed."; exit 0 ;;
  esac
fi

if [ "$KEEP_DATA" = "1" ]; then
  emit "{\"event\":\"start\",\"mode\":\"uninstall\",\"keep_data\":true}"
else
  emit "{\"event\":\"start\",\"mode\":\"uninstall\",\"keep_data\":false}"
fi

# ---------------------------------------------------------------------------
# 1. Docker: stop the stack, remove containers (+ volumes unless --keep-data),
#    verify the removal actually happened, then remove the syrus images. An
#    unreachable daemon skips this whole section with a warning — file removal
#    below still runs, but the encryption keys are kept (see section 2) and
#    the run counts as partial.
step "Docker stack"
volumes_verified_gone=0
if [ "$docker_ready" = "1" ]; then
  emit_step docker_down start
  have_compose=0
  if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
    have_compose=1
  elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
    have_compose=1
  fi
  if [ "$KEEP_DATA" = "1" ]; then
    down_args=(down --remove-orphans)
  else
    down_args=(down -v --remove-orphans)
  fi
  if [ "$have_compose" = "1" ]; then
    if [ -f "$STATE_DIR/docker-compose.yml" ]; then
      # Run against the desktop install's compose file; --project-directory
      # makes its relative env_file resolve no matter where we were invoked.
      run_logged docker compose -p syrus -f "$STATE_DIR/docker-compose.yml" \
        --project-directory "$STATE_DIR" "${down_args[@]}" || true
    else
      # Clone-dir installs keep their compose file elsewhere; newer compose
      # can tear a project down by name alone. Older ones fail harmlessly —
      # the direct removal below finishes the job.
      run_logged docker compose -p syrus "${down_args[@]}" || true
    fi
  fi
  # Belt and braces for whatever compose couldn't reach (no compose file, no
  # compose plugin, a half-removed stack): enumerate the project's actual
  # containers by compose label and remove them by ID.
  container_ids="$(list_syrus_containers)"
  if [ -n "$container_ids" ]; then
    # shellcheck disable=SC2086 # container IDs are single tokens; splitting is the point
    docker rm -f $container_ids >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_DATA" != "1" ]; then
    volume_names="$(list_syrus_volumes)"
    if [ -n "$volume_names" ]; then
      # shellcheck disable=SC2086 # volume names are single tokens; splitting is the point
      docker volume rm $volume_names >/dev/null 2>&1 || true
    fi
  fi
  # Trust nothing: re-list and report honestly. Only a clean re-list counts
  # as success — and (without --keep-data) unlocks deleting the encryption
  # keys in section 2.
  leftover_containers="$(list_syrus_containers)"
  leftover_volumes=""
  if [ "$KEEP_DATA" != "1" ]; then
    leftover_volumes="$(list_syrus_volumes)"
  fi
  if [ -z "$leftover_containers" ] && [ -z "$leftover_volumes" ]; then
    if [ "$KEEP_DATA" != "1" ]; then
      volumes_verified_gone=1
      info "Containers and data volumes removed (verified: none left)."
    else
      info "Containers removed (data volumes kept)."
    fi
    emit_step docker_down ok
  else
    leftovers="$(printf '%s %s' "$leftover_containers" "$leftover_volumes" | tr '\n' ' ')"
    leftovers="$(printf '%s' "$leftovers" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
    info "WARNING: docker teardown left something behind: $leftovers"
    emit_log docker "teardown left behind: $leftovers"
    emit_step docker_down failed "leftovers: $leftovers"
    add_partial "docker teardown left behind: $leftovers"
  fi

  emit_step docker_images start
  removed_images=0
  kept_images=0
  while read -r repo tag; do
    [ -n "$repo" ] || continue
    [ -n "$tag" ] || continue
    [ "$repo" = "<none>" ] && continue
    [ "$tag" = "<none>" ] && continue
    # Exact repository BASENAME match (mirrors desktop/electron/installer/
    # imageCleanup.ts): a user's unrelated `my-syrus-backend` never matches.
    case "${repo##*/}" in
      syrus-backend|syrus-local)
        ref="$repo:$tag"
        # Plain rmi by repo:tag, never -f: -f would untag EVERY tag sharing
        # the image ID (a user's backup tag included). An image still
        # referenced by a container refuses politely and stays.
        if docker rmi "$ref" >/dev/null 2>&1; then
          info "Removed image $ref"
          emit_log docker "removed image $ref"
          removed_images=$((removed_images + 1))
        else
          info "Left image $ref in place (still referenced, or removal failed)"
          emit_log docker "left image $ref in place (still referenced, or removal failed)"
          kept_images=$((kept_images + 1))
        fi
        ;;
    esac
  done < <(docker images --format '{{.Repository}} {{.Tag}}' 2>/dev/null | sort -u)
  if [ "$removed_images" = "0" ] && [ "$kept_images" = "0" ]; then
    info "No syrus images found."
    emit_step docker_images ok "none found"
  elif [ "$kept_images" = "0" ]; then
    emit_step docker_images ok "$removed_images removed"
  else
    emit_step docker_images ok "$removed_images removed, $kept_images left in place"
  fi
else
  info "Docker is not reachable — skipping containers, volumes, and images."
  emit_log docker "docker unavailable; skipping container, volume, and image removal"
  emit_step docker_down skipped "docker unavailable"
  emit_step docker_images skipped "docker unavailable"
  add_partial "docker unreachable: containers, volumes, and images were not removed"
fi

# ---------------------------------------------------------------------------
# 2. Files: install state, credentials, CLI, skill.
step "Files"
if [ "$KEEP_DATA" = "1" ]; then
  emit_step state_dir skipped "--keep-data"
  emit_step credentials skipped "--keep-data"
else
  if [ "$volumes_verified_gone" = "1" ]; then
    remove_step state_dir "$STATE_DIR" "install state (encryption keys, .env, compose file, install log)"
  elif [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    # THE ENCRYPTION-KEY GATE: the data volumes were NOT verifiably removed
    # (Docker unreachable, or a volume survived teardown). Deleting the .env
    # now would strand an encrypted volume with no keys — install.sh's
    # exit-20 guard would then refuse every reinstall, and the compose file
    # needed for `docker compose down -v` would be gone too. Keep the whole
    # directory; starting Docker and re-running this uninstaller finishes.
    info "WARNING: keeping $STATE_DIR — the syrus docker data volumes were not"
    info "         verifiably removed, and its .env holds the only ENCRYPTION"
    info "         KEYS for them. Start Docker and re-run this uninstaller to"
    info "         remove the volumes and then the keys."
    emit_log files "kept $STATE_DIR: data volumes not verifiably removed; start Docker and re-run to finish"
    emit_step state_dir failed "kept: data volumes not verifiably removed"
    add_partial "kept $STATE_DIR (encryption keys) until the docker data volumes are removed"
  else
    emit_step state_dir skipped "not present"
  fi
  remove_step credentials "$CREDENTIALS_FILE" "app/CLI credentials"
fi
remove_step cli "$CLI_BIN" "the syrus CLI"
remove_step skill "$SKILL_DIR" "the Claude Code skill"

# ---------------------------------------------------------------------------
# 3. Desktop app + its settings.
step "Desktop app"
if command -v pgrep >/dev/null 2>&1 && pgrep -x Syrus >/dev/null 2>&1; then
  # Unlinking a running bundle works on macOS — removal proceeds either way.
  info "Syrus appears to be running — quit it after the uninstall finishes."
  emit_log files "the Syrus app appears to be running; quit it after the uninstall"
fi
remove_step desktop_app "$APP_PATH" "the desktop app"
case "$APP_PATH_STATUS" in
  "") ;; # --app-path not given
  ok)
    remove_step desktop_app_custom "$APP_PATH_EXTRA" "the desktop app (--app-path)" ;;
  not_present)
    emit_step desktop_app_custom skipped "not present" ;;
  duplicate)
    emit_step desktop_app_custom skipped "same as the default app path" ;;
  *)
    info "Ignoring invalid --app-path (nothing removed for it): ${APP_PATH_ARG:-<empty>}"
    emit_log files "ignored invalid --app-path: ${APP_PATH_ARG:-<empty>}"
    emit_step desktop_app_custom skipped "invalid --app-path ignored"
    ;;
esac
if [ "$OS" = "Darwin" ] && [ -d "/Applications/Syrus.app" ] && \
   [ "$APP_PATH_EXTRA_RESOLVED" != "/Applications/Syrus.app" ]; then
  info "Note: /Applications/Syrus.app also exists — drag it to the Trash yourself,"
  info "      or re-run with --app-path=/Applications/Syrus.app."
  emit_log files "/Applications/Syrus.app exists; not removed (pass --app-path=/Applications/Syrus.app to remove it)"
fi
if [ "$OS" != "Darwin" ]; then
  info "If you installed the AppImage, its location is user-chosen — delete it manually."
fi
if [ "$KEEP_DATA" = "1" ]; then
  emit_step app_settings skipped "--keep-data"
else
  remove_step app_settings "$SETTINGS_DIR" "desktop app settings"
fi

# ~/.syrus itself goes only when nothing else (e.g. the clone cache from a
# bare-metal install, or the encryption keys kept by the gate above) still
# lives in it.
rmdir "$HOME/.syrus" >/dev/null 2>&1 || true

if [ "$PARTIAL" = "1" ]; then
  step "Done — with warnings"
  info "Syrus was only PARTIALLY removed: $PARTIAL_REASONS"
  info "Re-run this uninstaller after fixing the above (usually: start Docker)."
  printf '\033[1;33mWarning: partial uninstall — %s\033[0m\n' "$PARTIAL_REASONS" >&2
  emit "{\"event\":\"error\",\"code\":3,\"step\":\"$(json_escape "$CURRENT_STEP")\",\"message\":\"partial uninstall: $(json_escape "$PARTIAL_REASONS")\"}"
  exit 3
fi

step "Done"
info "Syrus has been removed."
info "NOT touched: Docker Desktop / OrbStack / Colima, Homebrew, rbenv — shared"
info "tools with their own uninstallers."
emit "{\"event\":\"done\"}"
