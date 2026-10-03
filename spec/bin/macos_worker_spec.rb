# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "native macOS worker scripts" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:entrypoint) { File.join(root, "bin/macos-worker") }
  let(:check) { File.join(root, "bin/macos-worker-check") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def write_env(path, overrides = {})
    values = {
      "SYRUS_DATA_ROOT" => "/var/lib/syrus",
      "SYRUS_APP_HOST" => "syrus.example.internal",
      "SYRUS_WORKER_POOL_NAME" => "macos-xcode",
      "SYRUS_WORKER_CAPABILITIES" => "os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator",
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

  def with_stubbed_host_bin(dir, xcode_select_path: "/Applications/Xcode.app/Contents/Developer")
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)

    write_stub(File.join(bin_dir, "uname"), "#!/usr/bin/env bash\necho Darwin\n")
    write_stub(File.join(bin_dir, "ruby"), "#!/usr/bin/env bash\necho ruby 3.4.10\n")
    write_stub(File.join(bin_dir, "bundle"), "#!/usr/bin/env bash\necho Bundler version 2.7.2\n")
    write_stub(File.join(bin_dir, "node"), "#!/usr/bin/env bash\necho v24.0.0\n")
    write_stub(File.join(bin_dir, "npm"), "#!/usr/bin/env bash\necho 11.0.0\n")
    write_stub(File.join(bin_dir, "git"), "#!/usr/bin/env bash\necho git version 2.50.0\n")
    write_stub(File.join(bin_dir, "xcode-select"), "#!/usr/bin/env bash\necho #{xcode_select_path}\n")
    write_stub(File.join(bin_dir, "xcodebuild"), "#!/usr/bin/env bash\necho Xcode 16.4\necho Build version 16F6\n")
    write_stub(File.join(bin_dir, "xcrun"), <<~BASH)
      #!/usr/bin/env bash
      echo '{"runtimes":[{"name":"iOS 18.5","isAvailable":true}]}'
    BASH

    bin_dir
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

  it "validates a macOS/Xcode host and production credentials without booting Rails" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
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
      expect(stdout).to include("OK   SOLID_QUEUE_CONFIG=config/queue.compute.yml")
      expect(stdout).to include("macos-worker-check: ok")
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
