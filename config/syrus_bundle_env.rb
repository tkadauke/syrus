# frozen_string_literal: true

root = File.expand_path("..", __dir__)
syrus_bundle_config = File.join(root, ".syrus", "deps", "bundle-config")
vendor_bundle = File.join(root, "vendor", "bundle")

ENV["BUNDLE_APP_CONFIG"] ||= syrus_bundle_config if Dir.exist?(syrus_bundle_config)
ENV["BUNDLE_PATH"] ||= vendor_bundle if Dir.exist?(vendor_bundle)
