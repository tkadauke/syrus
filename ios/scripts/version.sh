#!/usr/bin/env bash
# Print deterministic iOS version metadata.
# Usage: scripts/version.sh marketing|build|full
#
#   marketing  MARKETING_VERSION from project.yml (the single source of truth)
#   build      CFBundleVersion: SYRUS_IOS_BUILD_NUMBER if set, otherwise the
#              commit count of HEAD (monotonic on a linear main, identical for
#              every checkout of the same commit)
#   full       "<marketing> (<build>)"
set -euo pipefail
cd "$(dirname "$0")/.."

marketing() {
  local v
  v="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n1)"
  [[ -n "$v" ]] || { echo "version.sh: MARKETING_VERSION not found in project.yml" >&2; exit 1; }
  echo "$v"
}

build() {
  local n="${SYRUS_IOS_BUILD_NUMBER:-}"
  if [[ -z "$n" ]]; then
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
      echo "version.sh: shallow clone; fetch full history (git fetch --unshallow) or set SYRUS_IOS_BUILD_NUMBER" >&2
      exit 1
    fi
    n="$(git rev-list --count HEAD)"
  fi
  # App Store Connect accepts up to three period-separated integers.
  [[ "$n" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "version.sh: invalid build number '$n'" >&2; exit 1; }
  echo "$n"
}

case "${1:-}" in
  marketing) marketing ;;
  build) build ;;
  full) echo "$(marketing) ($(build))" ;;
  *) echo "usage: $0 marketing|build|full" >&2; exit 2 ;;
esac
