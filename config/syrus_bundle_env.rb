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
vendor_bundle = File.join(repo_root, "vendor", "bundle")
bundle_path_empty = ENV["BUNDLE_PATH"].to_s.empty?

if ENV["BUNDLE_APP_CONFIG"].to_s.empty? && File.file?(File.join(syrus_bundle_config, "config"))
  ENV["BUNDLE_APP_CONFIG"] = syrus_bundle_config
end

ENV["BUNDLE_PATH"] = syrus_bundle if bundle_path_empty && Dir.exist?(syrus_bundle)
ENV["BUNDLE_PATH"] = vendor_bundle if bundle_path_empty && ENV["BUNDLE_PATH"].to_s.empty? && Dir.exist?(vendor_bundle)

if bundle_path_empty && Dir.exist?(deps)
  ENV["BUNDLE_USER_HOME"] ||= File.join(deps, "bundle-home")
  ENV["BUNDLE_USER_CACHE"] ||= File.join(deps, "bundle-cache")
end
