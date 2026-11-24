#!/usr/bin/env bash
# Archive the Release configuration and optionally export/upload to TestFlight.
# Usage: scripts/release.sh archive|export|upload
#
# Credentials come from the operator environment, never the repository:
#   SYRUS_IOS_TEAM_ID                 Apple Developer Team ID (required)
#   SYRUS_IOS_BUNDLE_ID               optional bundle id override (default app.syrus.ios)
#   SYRUS_IOS_BUILD_NUMBER            optional CFBundleVersion (default: git commit count,
#                                     see scripts/version.sh)
#   ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID
#                                     App Store Connect API key (.p8) used for
#                                     provisioning updates and `upload`
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:-}"
: "${SYRUS_IOS_TEAM_ID:?set SYRUS_IOS_TEAM_ID to your Apple Developer Team ID}"
build_dir="build/release"
archive="$build_dir/Syrus.xcarchive"
export_dir="$build_dir/export"
build_number="$(scripts/version.sh build)"
marketing_version="$(scripts/version.sh marketing)"
log_dir="$build_dir/logs"
mkdir -p "$log_dir"

auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?ASC_KEY_ID required with ASC_KEY_PATH}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID required with ASC_KEY_PATH}"
  auth_args=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

render_export_options() { # $1 = export | upload
  mkdir -p "$build_dir"
  local destination=export
  [[ "$1" == upload ]] && destination=upload
  sed -e "s/__TEAM_ID__/$SYRUS_IOS_TEAM_ID/" -e "s/__DESTINATION__/$destination/" \
    ExportOptions.plist.template > "$build_dir/ExportOptions.plist"
}

do_archive() {
  xcodegen generate
  local overrides=(DEVELOPMENT_TEAM="$SYRUS_IOS_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number")
  [[ -n "${SYRUS_IOS_BUNDLE_ID:-}" ]] && overrides+=(PRODUCT_BUNDLE_IDENTIFIER="$SYRUS_IOS_BUNDLE_ID")
  rm -rf "$archive"
  # Only build settings and the ASC key *path* reach the log; key contents
  # never leave the file they live in.
  xcodebuild -project Syrus.xcodeproj -scheme Syrus -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    ${auth_args[@]+"${auth_args[@]}"} "${overrides[@]}" archive 2>&1 | tee "$log_dir/archive.log"
  write_metadata
}

write_metadata() {
  cat > "$build_dir/metadata.txt" <<META
marketing_version=$marketing_version
build_number=$build_number
git_commit=$(git rev-parse HEAD)
bundle_id=${SYRUS_IOS_BUNDLE_ID:-app.syrus.ios}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META
}

case "$action" in
  archive) do_archive ;;
  export)
    [[ -d "$archive" ]] || do_archive
    render_export_options export
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
      -exportOptionsPlist "$build_dir/ExportOptions.plist" ${auth_args[@]+"${auth_args[@]}"} \
      2>&1 | tee "$log_dir/export.log"
    ;;
  upload)
    [[ -n "${ASC_KEY_PATH:-}" ]] || { echo "upload requires ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID" >&2; exit 2; }
    [[ -d "$archive" ]] || do_archive
    render_export_options upload
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
      -exportOptionsPlist "$build_dir/ExportOptions.plist" "${auth_args[@]}" \
      2>&1 | tee "$log_dir/upload.log"
    ;;
  *) echo "usage: $0 archive|export|upload" >&2; exit 2 ;;
esac
