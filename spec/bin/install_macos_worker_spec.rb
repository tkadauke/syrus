# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "macOS worker installer" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/install-macos-worker") }

  it "defines the complete baseline and pinned agent CLIs" do
    source = File.read(script)

    expect(source).to include("ruby@3.4 node@22 mysql-client pkg-config vips openssl@3 readline libyaml mise go")
    expect(source).to include('CLAUDE_CODE_VERSION="2.1.296"')
    expect(source).to include('CODEX_CLI_VERSION="0.162.1"')
    expect(source).to include('git config --global credential.helper ""')
  end

  it "keeps agent CLI pins aligned with the worker container" do
    dockerfile = File.read(File.join(root, "Dockerfile"))
    source = File.read(script)

    claude_version = dockerfile.match(/^ARG CLAUDE_CODE_VERSION=(.+)$/)[1]
    codex_version = dockerfile.match(/^ARG CODEX_CLI_VERSION=(.+)$/)[1]
    expect(source).to include(%(CLAUDE_CODE_VERSION="#{claude_version}"))
    expect(source).to include(%(CODEX_CLI_VERSION="#{codex_version}"))
  end

  it "rejects polluted env files before making host changes" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      File.write(env_file, "SYRUS_DATA_ROOT=/tmp/syrus\napp_settings loaded\n")
      shim_dir = File.join(dir, "bin")
      Dir.mkdir(shim_dir)
      uname = File.join(shim_dir, "uname")
      File.write(uname, "#!/usr/bin/env sh\nprintf 'Darwin\\n'\n")
      File.chmod(0o755, uname)

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{shim_dir}:/usr/bin:/bin",
          "SUDO_USER" => ENV.fetch("USER", "syrus-test"),
          "USER" => "root"
        },
        "bash", script, "--dry-run", "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status).not_to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("contains lines that are not dotenv assignments")
    end
  end

  it "documents dependency-only and service activation controls" do
    stdout, stderr, status = Open3.capture3("bash", script, "--help")

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include("--skip-dependencies")
    expect(stdout).to include("--skip-services")
    expect(stdout).to include("sudo bin/install-macos-worker")
  end
end
