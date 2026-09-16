# frozen_string_literal: true

require "open3"
require "rails_helper"

RSpec.describe "bin/syrus-mcp-sidecar" do
  let(:root) { Rails.root.to_s }
  let(:clean_env) do
    {
      "HOME" => ENV.fetch("HOME"),
      "PATH" => ENV.fetch("PATH"),
      "TMPDIR" => ENV["TMPDIR"]
    }.compact
  end

  it "does not log successful SystemExit shutdown as a startup failure" do
    Dir.mktmpdir do |dir|
      script = <<~RUBY
        require "fileutils"
        require_relative "config/environment"

        bootstrap_path = File.expand_path("lib/syrus_sidecar_bootstrap.rb", Dir.pwd)
        unless File.exist?(bootstrap_path)
          FileUtils.mkdir_p(File.dirname(bootstrap_path))
          File.write(bootstrap_path, <<~BOOTSTRAP)
            require "fileutils"

            module SyrusSidecarBootstrap
              def self.prepare_bundle!(sidecar_env_key:)
              end

              def self.open_run_stderr!(run_id:, server_name:)
                log_dir = File.join(ENV.fetch("SYRUS_DATA_ROOT"), "mcp-sidecar-logs")
                FileUtils.mkdir_p(log_dir)
                $stderr.reopen(File.join(log_dir, "run-\#{run_id}.stderr.log"), "a")
                $stderr.sync = true
                warn "[syrus-mcp-sidecar] starting \#{server_name}"
              end
            end
          BOOTSTRAP
        end

        Mcp::Sidecar.singleton_class.define_method(:workflow) do |run_id:|
          Object.new.tap do |sidecar|
            sidecar.define_singleton_method(:run) { raise SystemExit.new(0) }
          end
        end

        ARGV.replace(["--run-id", "123"])
        load "bin/syrus-mcp-sidecar"
      RUBY

      _stdout, stderr, status = Open3.capture3(
        clean_env.merge("SYRUS_DATA_ROOT" => dir),
        RbConfig.ruby,
        "-e",
        script,
        chdir: root,
        unsetenv_others: true
      )

      expect(status).to be_success, stderr
      sidecar_stderr = File.read(File.join(dir, "mcp-sidecar-logs", "run-123.stderr.log"))
      expect(sidecar_stderr).to include("starting syrus-mcp-sidecar")
      expect(sidecar_stderr).not_to include("failed to start for run")
      expect(sidecar_stderr).not_to include("SystemExit")
    end
  end

  it "does not activate date before Bundler selects the application bundle" do
    script = <<~RUBY
      begin
        load "bin/syrus-mcp-sidecar"
      rescue SystemExit
      end

      abort "date activated before Bundler setup" if Gem.loaded_specs.key?("date")
      %w[BUNDLE_APP_CONFIG BUNDLE_USER_HOME BUNDLE_USER_CACHE BUNDLE_BIN_PATH RUBYOPT].each do |key|
        abort "\#{key} leaked into sidecar boot" if ENV.key?(key)
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      clean_env.merge(
        "BUNDLE_APP_CONFIG" => "/workspace/.syrus/deps/bundle-config",
        "BUNDLE_USER_HOME" => "/workspace/.syrus/deps/bundle-home",
        "BUNDLE_USER_CACHE" => "/workspace/.syrus/deps/bundle-cache",
        "BUNDLE_BIN_PATH" => "/workspace/.syrus/deps/bundle/bin/bundle",
        "RUBYOPT" => "-W0"
      ),
      RbConfig.ruby,
      "-e",
      script,
      chdir: root,
      unsetenv_others: true
    )

    expect(status).to be_success, stderr
  end

  it "loads Octokit under the production sidecar bundle without the Faraday retry warning" do
    script = <<~RUBY
      require "octokit"

      handlers = Octokit::Default::MIDDLEWARE.handlers.map { |handler| handler.klass.name }
      abort "Octokit retry middleware missing" unless handlers.include?("Faraday::Retry::Middleware")
      Octokit::Client.new
    RUBY

    _stdout, stderr, status = Open3.capture3(
      clean_env.merge(
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
        "BUNDLE_PATH" => File.join(root, "vendor/bundle"),
        "BUNDLE_APP_CONFIG" => File.join(root, ".bundle"),
        "BUNDLE_WITHOUT" => "development:test"
      ),
      RbConfig.ruby,
      "-rbundler/setup",
      "-e",
      script,
      chdir: root,
      unsetenv_others: true
    )

    expect(status).to be_success, stderr
    expect(stderr).not_to include("To use retry middleware with Faraday v2.0+")
  end
end
