# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "native macOS worker scripts" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:entrypoint) { File.join(root, "bin/macos-worker") }
  let(:check) { File.join(root, "bin/macos-worker-check") }

  let(:pinned_ruby) { File.read(File.join(root, ".ruby-version")).strip }

  it "gives worker and updater services Homebrew's node and native build paths, but not its Ruby" do
    %w[com.syrus.worker.plist com.syrus.updater.plist].each do |name|
      plist = File.read(File.join(root, "config/launchd", name))

      # Ruby comes from the release's .ruby-version (bin/macos-ruby-env), so a
      # Homebrew upgrade cannot change it under a running worker.
      expect(plist).not_to include("ruby@")
      expect(plist).not_to include("BUNDLE_PATH")
      expect(plist).to include("/opt/homebrew/opt/node@22/bin")
      expect(plist).to include("/opt/homebrew/opt/mysql-client/bin")
      expect(plist).to include("/opt/homebrew/opt/mysql-client/lib/pkgconfig")
      expect(plist).to include("-I/opt/homebrew/opt/mysql-client/include")
    end
  end

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def write_env(path, overrides = {})
    values = {
      "SYRUS_DATA_ROOT" => "/var/lib/syrus",
      "SYRUS_APP_HOST" => "syrus.example.internal",
      "SYRUS_WORKER_POOL_NAME" => "macos-xcode",
      "SYRUS_WORKER_CAPABILITIES" => "os:macos",
      "SECRET_KEY_BASE" => "secret",
      "RAILS_MASTER_KEY" => "master",
      "DB_HOST" => "db.internal",
      "SYRUS_DATABASE_PASSWORD" => "password",
      "S3_ACCESS_KEY_ID" => "key",
      "S3_SECRET_ACCESS_KEY" => "secret",
      "S3_BUCKET" => "attachments",
      "S3_ENDPOINT" => "http://minio.internal:9000"
    }.merge(overrides)

    File.write(path, values.map { |key, value| "#{key}=#{value}\n" }.join)
  end

  # Answers the version probe like a real Ruby of `version` would.
  def fake_ruby_body(version)
    <<~BASH
      #!/usr/bin/env bash
      if [[ "$1" == "-e" && "$2" == "print RUBY_VERSION" ]]; then printf '%s' "#{version}"; exit 0; fi
      [[ "$1" == "-ropenssl" ]] && exit 0
      echo "ruby #{version}"
    BASH
  end

  def with_stubbed_host_bin(dir, xcode_select_path: "/Applications/Xcode.app/Contents/Developer", ruby_version: pinned_ruby)
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)

    write_stub(File.join(bin_dir, "uname"), "#!/usr/bin/env bash\necho Darwin\n")
    write_stub(File.join(bin_dir, "ruby"), fake_ruby_body(ruby_version))
    write_stub(File.join(bin_dir, "bundle"), "#!/usr/bin/env bash\necho Bundler version 2.7.2\n")
    write_stub(File.join(bin_dir, "node"), "#!/usr/bin/env bash\necho v24.0.0\n")
    write_stub(File.join(bin_dir, "npm"), "#!/usr/bin/env bash\necho 11.0.0\n")
    write_stub(File.join(bin_dir, "git"), "#!/usr/bin/env bash\necho git version 2.50.0\n")
    write_stub(File.join(bin_dir, "mise"), "#!/usr/bin/env bash\necho 2026.1.0\n")
    write_stub(File.join(bin_dir, "codex"), "#!/usr/bin/env bash\necho codex-cli 0.160.0\n")
    write_stub(File.join(bin_dir, "claude"), "#!/usr/bin/env bash\necho 2.1.289\n")
    write_stub(File.join(bin_dir, "xcode-select"), "#!/usr/bin/env bash\necho #{xcode_select_path}\n")
    write_stub(File.join(bin_dir, "xcodebuild"), "#!/usr/bin/env bash\necho Xcode 16.4\necho Build version 16F6\n")
    write_stub(File.join(bin_dir, "xcrun"), <<~BASH)
      #!/usr/bin/env bash
      echo '{"runtimes":[{"name":"iOS 18.5","isAvailable":true}]}'
    BASH

    bin_dir
  end

  it "defaults to the shared launchd worker env file path" do
    expect(File.read(entrypoint)).to include('DEFAULT_ENV_FILE="/etc/syrus/worker.env"')
    expect(File.read(check)).to include('DEFAULT_ENV_FILE="/etc/syrus/worker.env"')
  end

  it "starts the compute worker contract without consuming home queues" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "GIT_SHA" => "abc123")

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash",
        entrypoint,
        "--env-file",
        env_file,
        "--dry-run",
        "--",
        "--pidfile",
        "/tmp/syrus.pid",
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("SYRUS_ROLE=worker")
      expect(stdout).to include("GIT_SHA=abc123")
      expect(stdout).to include("SYRUS_DATA_ROOT=/var/lib/syrus")
      expect(stdout).to include("SYRUS_APP_HOST=syrus.example.internal")
      expect(stdout).to include("SYRUS_WORKER_POOL_NAME=macos-xcode")
      expect(stdout).to include("SOLID_QUEUE_CONFIG=config/queue.compute.yml")
      expect(stdout).to include("SOLID_QUEUE_SKIP_RECURRING=1")
      expect(stdout).to include("command=#{entrypoint.delete_suffix("macos-worker")}jobs --pidfile /tmp/syrus.pid")
    end
  end

  # Regression: the macOS worker reaches MySQL through kubectl port-forward,
  # where a dead stream leaves the local socket open; without socket timeouts
  # a query on it hung an MCP tool call past the agent's 120s limit.
  it "bounds MySQL socket operations by default and lets the env file override them" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      File.write(env_file, <<~ENV)
        SYRUS_DATA_ROOT=/var/lib/syrus
        SYRUS_APP_HOST=syrus.example.internal
        SYRUS_WORKER_POOL_NAME=macos-xcode
        SYRUS_WORKER_CAPABILITIES=os=macos
        DB_READ_TIMEOUT=45
      ENV

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash", entrypoint, "--env-file", env_file, "--dry-run",
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("DB_CONNECT_TIMEOUT=10")
      expect(stdout).to include("DB_READ_TIMEOUT=45")
      expect(stdout).to include("DB_WRITE_TIMEOUT=30")
    end
  end

  it "stamps the packaged release sha when the env file omits GIT_SHA" do
    packaged_sha = File.join(root, "GIT_SHA")

    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      File.write(packaged_sha, "packaged123\n")

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash",
        entrypoint,
        "--env-file",
        env_file,
        "--dry-run",
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("GIT_SHA=packaged123")
    ensure
      FileUtils.rm_f(packaged_sha)
    end
  end

  it "reports the installed release sha over a stale GIT_SHA left in the env file" do
    packaged_sha = File.join(root, "GIT_SHA")

    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "GIT_SHA" => "stale000")
      File.write(packaged_sha, "packaged123\n")

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash", entrypoint, "--env-file", env_file, "--dry-run"
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("GIT_SHA=packaged123")
      expect(stdout).not_to include("GIT_SHA=stale000")
      expect(stderr).to include("ignoring GIT_SHA=stale000")
    ensure
      FileUtils.rm_f(packaged_sha)
    end
  end

  it "validates a macOS/Xcode host and production credentials without booting Rails" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "GIT_SHA" => "abc123")
      bin_dir = with_stubbed_host_bin(dir)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        check,
        "--env-file",
        env_file,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("OK   host os: Darwin")
      expect(stdout).to include("OK   full Xcode selected")
      expect(stdout).to include("OK   iOS simulator runtimes: at least one available runtime")
      expect(stdout).to include("OK   release revision: abc123")
      expect(stdout).not_to include("has no .git directory")
      expect(stdout).to include("OK   SOLID_QUEUE_CONFIG=config/queue.compute.yml")
      expect(stdout).to include("OK   Ruby matches .ruby-version: #{pinned_ruby}")
      expect(stdout).to include("macos-worker-check: ok")
    end
  end

  it "fails validation when the Ruby on PATH is not the release's pinned Ruby" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir, ruby_version: "3.4.99")

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL Ruby on PATH is 3.4.99, but the release pins #{pinned_ruby}")
    end
  end

  it "gives in-flight runs an hour to drain on SIGTERM before launchd kills the worker" do
    plist = File.read(File.join(root, "config/launchd/com.syrus.worker.plist"))

    expect(plist).to match(%r{<key>ExitTimeOut</key>\s*<integer>3600</integer>})
    expect(File.read(entrypoint)).to include('SOLID_QUEUE_SHUTDOWN_TIMEOUT="${SOLID_QUEUE_SHUTDOWN_TIMEOUT:-3540}"')
  end

  it "reports the pinned Ruby and its own gem bundle in a dry run" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash", entrypoint, "--env-file", env_file, "--dry-run",
        unsetenv_others: true
      )

      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("RUBY=/opt/syrus/rubies/#{pinned_ruby}/bin/ruby")
      expect(stdout).to include("BUNDLE_PATH=/opt/syrus/shared/bundles/ruby-#{pinned_ruby}")
    end
  end

  it "refuses to start when the pinned Ruby is not installed instead of using the host's Ruby" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME"),
          "SYRUS_MACOS_RUBIES_ROOT" => File.join(dir, "rubies") },
        "bash", entrypoint, "--env-file", env_file, "--check",
        unsetenv_others: true
      )

      expect(status).not_to be_success
      expect(stdout).not_to include("macos-worker-check")
      expect(stderr).to include("Ruby #{pinned_ruby} (from #{root}/.ruby-version) is not installed under #{dir}/rubies")
    end
  end

  it "runs the worker on the pinned Ruby once it is installed" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "GIT_SHA" => "abc123")
      bin_dir = with_stubbed_host_bin(dir, ruby_version: "3.4.99")
      rubies = File.join(dir, "rubies")
      FileUtils.mkdir_p(File.join(rubies, pinned_ruby, "bin"))
      write_stub(File.join(rubies, pinned_ruby, "bin", "ruby"), fake_ruby_body(pinned_ruby))

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME"),
          "SYRUS_MACOS_RUBIES_ROOT" => rubies },
        "bash", entrypoint, "--env-file", env_file, "--check",
        unsetenv_others: true
      )

      # The host's own ruby (stubbed as 3.4.99) is shadowed by the pinned one.
      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("OK   Ruby matches .ruby-version: #{pinned_ruby}")
    end
  end

  it "fails validation when only Command Line Tools are selected" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir, xcode_select_path: "/Library/Developer/CommandLineTools")

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        check,
        "--env-file",
        env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL full Xcode must be selected")
      expect(stdout).to include("macos-worker-check: 1 failure(s)")
    end
  end

  it "reports missing environment instead of aborting when no env file is present" do
    Dir.mktmpdir do |dir|
      bin_dir = with_stubbed_host_bin(dir)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        check,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL env SYRUS_WORKER_CAPABILITIES is required")
      expect(stdout).to include("FAIL SYRUS_WORKER_CAPABILITIES should include os:macos")
      expect(stdout).to include("macos-worker-check: 16 failure(s)")
      expect(stderr).not_to include("unbound variable")
    end
  end

  it "fails validation before boot when production app host is missing" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "SYRUS_APP_HOST" => nil)
      bin_dir = with_stubbed_host_bin(dir)

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        check,
        "--env-file",
        env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL env SYRUS_APP_HOST is required")
    end
  end
end
