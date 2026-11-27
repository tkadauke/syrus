# frozen_string_literal: true

require "open3"
require "rails_helper"

# Regression: a macOS worker loaded Homebrew's libvips at boot -- from the
# Gemfile, the vips initializer, and the terminal renderer -- although it never
# processes an image, so another account upgrading Homebrew's vips could break
# the worker's boot. Each check runs in a fresh process so nothing this suite
# already loaded can hide a regression.
RSpec.describe "libvips at boot" do
  let(:root) { Rails.root.to_s }

  def ruby(script, env: {})
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", script, chdir: root)
    expect(status).to be_success, stderr
    stdout.strip
  end

  it "does not require ruby-vips through Bundler.require" do
    dependency = Bundler.definition.dependencies.find { |dep| dep.name == "ruby-vips" }

    expect(dependency.autorequire).to eq([])
  end

  it "loads the terminal renderer without loading vips" do
    loaded = ruby(<<~RUBY)
      require "bundler/setup"
      load "plugins/runtime_terminal/app/services/runtime_terminal/renderer.rb"
      puts $LOADED_FEATURES.grep(%r{/vips(\\.rb|/)}).empty? && !defined?(Vips)
    RUBY

    expect(loaded).to eq("true")
  end

  it "skips the vips initializer on hosts that disable libvips" do
    loaded = ruby(<<~RUBY, env: { "SYRUS_LIBVIPS" => "disabled" })
      require "bundler/setup"
      load "config/initializers/vips_security.rb"
      puts defined?(Vips).inspect
    RUBY

    expect(loaded).to eq("nil")
  end
end
