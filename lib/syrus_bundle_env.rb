# frozen_string_literal: true

module SyrusBundleEnv
  def self.apply
    root = File.expand_path("..", __dir__)
    deps_root = File.join(root, ".syrus", "deps")
    bundle_path = File.join(deps_root, "bundle")
    vendor_bundle = File.join(root, "vendor", "bundle")

    if ENV["BUNDLE_PATH"].to_s.empty?
      ENV["BUNDLE_PATH"] = if File.directory?(bundle_path)
        bundle_path
      elsif File.directory?(vendor_bundle)
        vendor_bundle
      end
    end

    return unless File.directory?(bundle_path)

    ENV["BUNDLE_APP_CONFIG"] = File.join(deps_root, "bundle-config") if ENV["BUNDLE_APP_CONFIG"].to_s.empty?
    ENV["BUNDLE_USER_CACHE"] = File.join(deps_root, "bundle-cache") if ENV["BUNDLE_USER_CACHE"].to_s.empty?
    ENV["BUNDLE_USER_HOME"] = File.join(deps_root, "bundle-home") if ENV["BUNDLE_USER_HOME"].to_s.empty?
  end
end

SyrusBundleEnv.apply
