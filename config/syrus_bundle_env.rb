# frozen_string_literal: true

# Syrus prepare installs dependencies with Bundler config isolated under
# .syrus/deps so agent runs don't inherit the worker pod's Bundler state.
# Some grader subprocesses intentionally strip BUNDLE_* env vars before
# invoking binstubs; when that happens, teach Bundler where the prepared
# local config lives without affecting normal developer or production envs.
repo_root = File.expand_path("..", __dir__)
deps = File.join(repo_root, ".syrus", "deps")
syrus_bundle_config = File.join(deps, "bundle-config")
syrus_bundle = File.join(deps, "bundle")
vendor_bundle_config = File.join(repo_root, ".bundle")
vendor_bundle = File.join(repo_root, "vendor", "bundle")
current_bundle_path = ENV["BUNDLE_PATH"].to_s
local_ruby_version = RbConfig::CONFIG.fetch("ruby_version")

bundle_installed = lambda do |path|
  pattern = File.join(path, "ruby", local_ruby_version, "specifications", "*.gemspec")
  !Dir.glob(pattern).empty?
end

configured_bundle = lambda do |config_dir, path|
  File.file?(File.join(config_dir, "config")) && bundle_installed.call(path)
end

bundle_path_absent = current_bundle_path.empty?
# Also override when BUNDLE_PATH is set but points to a location with no gems,
# which happens when the Syrus worker env is inherited by grader subprocesses
# that run in a workspace where gems live in vendor/bundle instead.
bundle_path_stale = !bundle_path_absent && !bundle_installed.call(current_bundle_path)

prepared_bundle = [
  [ syrus_bundle_config, syrus_bundle ],
  [ vendor_bundle_config, vendor_bundle ]
].find { |config_dir, path| configured_bundle.call(config_dir, path) }&.last

ENV["BUNDLE_PATH"] = prepared_bundle if (bundle_path_absent || bundle_path_stale) && prepared_bundle

if (bundle_path_absent || bundle_path_stale) && prepared_bundle == syrus_bundle
  ENV["BUNDLE_APP_CONFIG"] ||= syrus_bundle_config
  ENV["BUNDLE_USER_HOME"] ||= File.join(deps, "bundle-home")
  ENV["BUNDLE_USER_CACHE"] ||= File.join(deps, "bundle-cache")
elsif (bundle_path_absent || bundle_path_stale) && prepared_bundle
  # Vendor-bundle fallback: if BUNDLE_APP_CONFIG points to a path that does not
  # exist (e.g. the stale Syrus worker deps config inherited by grader subprocesses),
  # clear it so bundler resolves config from the project's .bundle/config instead of
  # falling back to ~/.bundle/config and inadvertently ignoring the workspace bundle.
  app_config = ENV["BUNDLE_APP_CONFIG"].to_s
  ENV.delete("BUNDLE_APP_CONFIG") if !app_config.empty? && !File.exist?(app_config)
end
