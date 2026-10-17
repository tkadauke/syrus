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

  it "keeps privileged code and releases root-owned" do
    source = File.read(script)
    updater_plist = File.read(File.join(root, "config/launchd/com.syrus.updater.plist"))

    expect(source).to include('chown -R root:wheel "$INSTALL_ROOT" "$LIBEXEC_ROOT"')
    expect(source).to include('install -o root -g wheel -m 755 "$RELEASE_PATH/bin/syrus-macos-updater" "$LIBEXEC_ROOT/syrus-macos-updater"')
    expect(source).to include('chown -R root:wheel "$RELEASE_PATH"')
    expect(source).not_to include('chown -R "$SERVICE_USER:$SERVICE_GROUP" "$RELEASE_PATH"')
    expect(updater_plist).to include("/usr/local/libexec/syrus/syrus-macos-updater")
    expect(updater_plist).not_to include("/opt/syrus/current/bin/syrus-macos-updater")
  end

  it "replaces legacy and repeated-install node_modules paths before linking shared dependencies" do
    Dir.mktmpdir do |dir|
      install_root = File.join(dir, "install")
      release_sha = `git -C #{root} rev-parse --short=10 HEAD`.strip
      release_path = File.join(install_root, "releases", release_sha)
      env_file = File.join(dir, "worker.env")
      shim_dir = File.join(dir, "bin")
      FileUtils.mkdir_p([ release_path, shim_dir ])
      File.write(env_file, "SYRUS_APP_HOST=https://syrus.example.test\n")
      File.write(File.join(shim_dir, "uname"), "#!/usr/bin/env sh\nprintf 'Darwin\\n'\n")
      File.write(File.join(shim_dir, "dscl"), <<~SH)
        #!/usr/bin/env sh
        if [ "$3" = "PrimaryGroupID" ]; then printf 'PrimaryGroupID: 450\\n'; fi
        exit 0
      SH
      FileUtils.chmod(0o755, Dir[File.join(shim_dir, "*")])

      [ :legacy_directory, :existing_symlink ].each do |layout|
        node_modules = File.join(release_path, "node_modules")
        FileUtils.rm_rf(node_modules)
        if layout == :legacy_directory
          FileUtils.mkdir_p(node_modules)
        else
          File.symlink(File.join(dir, "prior-node-modules"), node_modules)
        end

        stdout, stderr, status = Open3.capture3(
          {
            "PATH" => "#{shim_dir}:/usr/bin:/bin",
            "SUDO_USER" => ENV.fetch("USER", "syrus-test"),
            "USER" => "root"
          },
          "bash", script, "--dry-run", "--skip-dependencies", "--skip-services",
          "--env-file", env_file, "--install-root", install_root,
          unsetenv_others: true
        )

        expect(status).to be_success, "#{layout}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
        remove_offset = stdout.index("rm -rf #{node_modules}")
        link_offset = stdout.index("ln -s #{install_root}/shared/node/#{release_sha}/node_modules #{node_modules}")
        expect(remove_offset).not_to be_nil
        expect(link_offset).to be > remove_offset
      end
    end
  end
end
