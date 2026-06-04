# frozen_string_literal: true

root = File.expand_path("..", __dir__)
syrus_bundle_config = File.join(root, ".syrus", "deps", "bundle-config")
syrus_bundle = File.join(root, ".syrus", "deps", "bundle")
vendor_bundle = File.join(root, "vendor", "bundle")

ENV["BUNDLE_APP_CONFIG"] = syrus_bundle_config if ENV["BUNDLE_APP_CONFIG"].to_s.empty? && Dir.exist?(syrus_bundle)
ENV["BUNDLE_PATH"] = syrus_bundle if ENV["BUNDLE_PATH"].to_s.empty? && Dir.exist?(syrus_bundle)
ENV["BUNDLE_PATH"] = vendor_bundle if ENV["BUNDLE_PATH"].to_s.empty? && Dir.exist?(vendor_bundle)
