# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "bin/check-thread-budget" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-thread-budget") }
  let(:queue_concurrency_env) do
    %w[
      CHAT_CONCURRENCY
      CLEANUP_CONCURRENCY
      CONTROL_PLANE_CONCURRENCY
      INDEXING_CONCURRENCY
      LOW_PRIORITY_MAINTENANCE_CONCURRENCY
      MERGE_CONCURRENCY
      OPERATOR_ACTION_CONCURRENCY
      PLUGIN_JOB_THREADS
      POLLING_CONCURRENCY
      VIDEO_CONCURRENCY
    ].to_h { |key| [ key, nil ] }
  end

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
      # Keep ERB-rendering examples independent of the CI runner's CPU quota
      # and ambient worker settings. The checker itself still honors explicit
      # overrides passed by an example.
      env = ENV.to_h
        .merge(queue_concurrency_env)
        .merge(
          bundler_install_env,
          "DB_POOL" => nil,
          "JOB_CONCURRENCY" => "6",
          "SYRUS_WORKER_CPU_LIMIT" => "4"
        )
        .merge(env_overrides)
      Open3.capture3(env, RbConfig.ruby, script, unsetenv_others: true, chdir: root)
    end
  end

  it "renders Rails-style config ERB before checking queue thread budget" do
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH")
    )

    expect(status).to be_success, "expected success, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
    expect(stderr).to be_empty
  end

  it "does not inherit queue concurrency overrides from the test runner" do
    original_merge_concurrency = ENV["MERGE_CONCURRENCY"]
    ENV["MERGE_CONCURRENCY"] = "20"
    begin
      stdout, stderr, status = spawn_clean(
        "HOME" => ENV.fetch("HOME"),
        "PATH" => ENV.fetch("PATH")
      )

      expect(status).to be_success, "expected success, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("[check-thread-budget] ok")
      expect(stderr).to be_empty
    ensure
      ENV["MERGE_CONCURRENCY"] = original_merge_concurrency
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

  it "fits the default MySQL pool around a six-thread run worker" do
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "JOB_CONCURRENCY" => "6",
      "SYRUS_SQLITE" => nil
    )

    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to match(/threads=6, pool: \d+, required: 9/)
    expect(stdout[/threads=6, pool: (\d+)/, 1].to_i).to be >= 9
    expect(stderr).to be_empty
  end

  # Regression: a 16-CPU compute pod claims 12 Runs at once, but the pool
  # stayed at 9, so every Run thread past the ninth timed out waiting for a
  # connection.
  it "sizes the default MySQL pool to a large compute pod's run worker" do
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "JOB_CONCURRENCY" => nil,
      "SYRUS_WORKER_CPU_LIMIT" => "16",
      "SYRUS_SQLITE" => nil
    )

    expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to match(/queue\.compute\.yml \(worst worker: queues=.* threads=12, pool: (\d+)/)
    expect(stdout[/queue\.compute\.yml.*?pool: (\d+)/, 1].to_i).to be >= 15
  end

  # The check used to run as a standalone grader on whatever worker picked
  # it up, so its verdict followed that worker's CPU count: the same commit
  # passed on a 6-core worker and failed on a 16-core one. It now runs only
  # here, against fixed pod sizes, so a pool that cannot cover any supported
  # size fails on every run.
  [ 4, 16, 32 ].each do |cpus|
    it "fits every queue config on a #{cpus}-CPU pod" do
      stdout, stderr, status = spawn_clean(
        "HOME" => ENV.fetch("HOME"),
        "PATH" => ENV.fetch("PATH"),
        "JOB_CONCURRENCY" => nil,
        "SYRUS_WORKER_CPU_LIMIT" => cpus.to_s,
        "SYRUS_SQLITE" => nil
      )

      expect(status).to be_success, "#{cpus} CPUs: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout.scan("[check-thread-budget] ok").size).to eq(3)
    end
  end

  it "keeps an explicit DB_POOL" do
    stdout, _stderr, _status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "DB_POOL" => "40",
      "SYRUS_SQLITE" => nil
    )

    expect(stdout).to include("pool: 40")
  end

  it "finds gems when BUNDLE_PATH is set to an empty Syrus worker path (main grader scenario)" do
    # When MainGraderWorkflowJob runs graders, the Syrus worker's env has
    # BUNDLE_PATH pointing to its own bundle cache (.syrus/deps/bundle), which
    # has no gems. syrus_bundle_env.rb must detect this as stale and fall back
    # to vendor/bundle so graders that don't prefix BUNDLE_PATH overrides still work.
    stdout, stderr, status = spawn_clean(
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "BUNDLE_PATH" => File.join(root, ".syrus", "deps", "bundle"),
      "BUNDLE_APP_CONFIG" => File.join(root, ".syrus", "deps", "bundle-config")
    )

    expect(status).to be_success, "expected success with stale BUNDLE_PATH, got #{status.exitstatus}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
    expect(stdout).to include("[check-thread-budget] ok")
  end
end
