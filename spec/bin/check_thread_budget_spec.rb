# frozen_string_literal: true

require "open3"
require "spec_helper"

RSpec.describe "bin/check-thread-budget" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-thread-budget") }

  def spawn_clean(env_overrides = {})
    bundler_install_env = ENV.to_h.select do |key, _|
      %w[
        BUNDLE_APP_CONFIG
        BUNDLE_DEPLOYMENT
        BUNDLE_PATH
        BUNDLE_USER_CACHE
        BUNDLE_USER_HOME
        BUNDLE_WITHOUT
      ].include?(key)
    end

    Bundler.with_unbundled_env do
      env = ENV.to_h.merge(bundler_install_env).merge(env_overrides)
      Open3.capture3(env, "ruby", script, unsetenv_others: true, chdir: root)
    end
  end

  it "renders Rails-style database.yml ERB outside Rails in a fresh process" do
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "RAILS_MAX_THREADS" => "10",
      "SYRUS_SQLITE" => nil
    )

    expect(stderr).not_to include("Gem::LoadError")
    expect(stderr).not_to include("undefined method `present?'")
    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).to be_empty
  end

  it "renders the production SQLite branch without Rails present? helpers loaded" do
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "RAILS_MAX_THREADS" => "10",
      "SYRUS_SQLITE" => "1"
    )

    expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).not_to include("undefined method `present?'")
  end
end
