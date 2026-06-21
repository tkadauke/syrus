require "rails_helper"
require "open3"

RSpec.describe "bin/check-thread-budget" do
  let(:script) { Rails.root.join("bin/check-thread-budget").to_s }

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
      Open3.capture3(env, "ruby", script, unsetenv_others: true)
    end
  end

  it "renders Rails-style config ERB helpers in a fresh process before checking queue thread budget" do
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
end
