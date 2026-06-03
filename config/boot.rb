ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
workspace_bundle = File.expand_path("../vendor/bundle", __dir__)
ENV["BUNDLE_PATH"] ||= workspace_bundle if Dir.exist?(workspace_bundle)

require_relative "syrus_bundle_env"

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
