# frozen_string_literal: true

require "open3"
require "rails_helper"

# Regression: a macOS worker loaded Homebrew's libvips at boot although it
# never processes an image, so another account upgrading Homebrew's vips could
# break the worker. An environment switch could not prevent it: Active
# Storage's engine config loads ruby-vips on every boot whenever the gem is in
# the bundle. Mac workers therefore bundle without the images group. Each check
# runs in a fresh process so nothing this suite already loaded can hide a
# regression.
RSpec.describe "libvips at boot" do
  let(:root) { Rails.root.to_s }

  def ruby(script, env: {})
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", script, chdir: root)
    expect(status).to be_success, stderr
    stdout.strip
  end

  it "keeps the image gems in a group that Bundler.require never loads" do
    %w[image_processing ruby-vips].each do |name|
      dependency = Bundler.definition.dependencies.find { |dep| dep.name == name }

      expect(dependency.groups).to eq([ :images ]), name
      expect(dependency.autorequire).to eq([]), name
    end
  end

  it "loads the terminal renderer without loading vips" do
    loaded = ruby(<<~RUBY)
      require "bundler/setup"
      load "plugins/runtime_terminal/app/services/runtime_terminal/renderer.rb"
      puts $LOADED_FEATURES.grep(%r{/vips(\\.rb|/)}).empty? && !defined?(Vips)
    RUBY

    expect(loaded).to eq("true")
  end

  it "boots and eager-loads the app without libvips when bundled the way a Mac worker is" do
    loaded = ruby(<<~RUBY, env: { "BUNDLE_WITHOUT" => "images", "RAILS_ENV" => "test" })
      require "./config/environment"
      Rails.application.eager_load!
      puts [ defined?(Vips).inspect, ActiveStorage::VIPS_AVAILABLE ].inspect
    RUBY

    expect(loaded).to eq('["nil", false]')
  end
end
