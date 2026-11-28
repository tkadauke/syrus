# frozen_string_literal: true

require "open3"
require "shellwords"
require "tmpdir"
require "spec_helper"

RSpec.describe "macOS worker installer" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/install-macos-worker") }

  it "defines the complete baseline and pinned agent CLIs" do
    source = File.read(script)

    # Nothing comes from Homebrew, which other accounts on the host can
    # upgrade: the release's toolchain comes from bin/macos-runtime-env.
    expect(source).not_to match(%r{brew install|/opt/homebrew|BREW_FORMULAE})
    expect(source).to include('CLAUDE_CODE_VERSION="2.1.330"')
    expect(source).to include('CODEX_CLI_VERSION="0.171.0"')
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

  def write_public_key(dir)
    private_key = File.join(dir, "signing.pem")
    public_key = File.join(dir, "public.pem")
    system("openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private_key,
      out: File::NULL, err: File::NULL, exception: true)
    system("openssl", "pkey", "-in", private_key, "-pubout", "-out", public_key, out: File::NULL, err: File::NULL, exception: true)
    public_key
  end

  # A host installed without the key installs fine and then silently never
  # applies another deploy's release.
  it "refuses to install without the release signing public key, before any host change" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      File.write(env_file, "SYRUS_APP_HOST=https://syrus.example.test\n")
      shim_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(shim_dir)
      File.write(File.join(shim_dir, "uname"), "#!/usr/bin/env sh\nprintf 'Darwin\\n'\n")
      FileUtils.chmod(0o755, File.join(shim_dir, "uname"))

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{shim_dir}:/usr/bin:/bin", "SUDO_USER" => ENV.fetch("USER", "syrus-test"), "USER" => "root" },
        "bash", script, "--dry-run", "--env-file", env_file, "--update-public-key", File.join(dir, "missing.pem"),
        unsetenv_others: true
      )

      expect(status).not_to be_success
      expect(stdout).to be_empty
      expect(stderr).to include("install the release signing public key at #{dir}/missing.pem first")
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
      public_key = write_public_key(dir)
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
          "bash", script, "--dry-run", "--skip-services",
          "--env-file", env_file, "--install-root", install_root, "--update-public-key", public_key,
          unsetenv_others: true
        )

        expect(status).to be_success, "#{layout}: stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
        mysql_version = File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^MYSQL_CLIENT_VERSION=(.+)$/, 1]
        mise_version = File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^MISE_VERSION=(.+)$/, 1]
        # mysql2 builds against the release's pinned MySQL client, and a
        # Homebrew build setting left by an older install is cleared.
        expect(stdout).to include("BUNDLE_BUILD__MYSQL2=--with-mysql-config=#{install_root}/tools/mysql-client/#{mysql_version}/bin/mysql_config")
        expect(stdout).to include("bundle config unset --local build.mysql2")
        expect(stdout).to include("BUNDLE_WITHOUT=images")
        remove_offset = stdout.index("rm -rf #{node_modules}")
        link_offset = stdout.index("ln -s #{install_root}/shared/node/#{release_sha}/node_modules #{node_modules}")
        expect(remove_offset).not_to be_nil
        expect(link_offset).to be > remove_offset
        expect(stdout).to include("BUNDLE_FROZEN=true bundle install")
        expect(stdout).to include("mv -h -f #{install_root}/current.next #{install_root}/current")
        pinned_ruby = File.read(File.join(root, ".ruby-version")).strip
        install_offset = stdout.index("+ syrus_macos_runtimes_install #{root}")
        expect(install_offset).not_to be_nil
        expect(install_offset).to be < stdout.index("bundle install")
        pinned_node = File.read(File.join(root, ".node-version")).strip
        # The pinned toolchain, then only the system's own directories. The
        # private MySQL client's bin is on it so a job's own mysql2 build finds
        # that mysql_config before mysql2's built-in Homebrew locations, and
        # XcodeGen's, and the browser tools' bin for playwright-mcp.
        playwright = File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^PLAYWRIGHT_VERSION=(.+)$/, 1]
        playwright_mcp = File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^PLAYWRIGHT_MCP_VERSION=(.+)$/, 1]
        xcodegen = File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^XCODEGEN_VERSION=(.+)$/, 1]
        expect(stdout).to include(
          "PATH=#{install_root}/rubies/#{pinned_ruby}/bin:#{install_root}/nodes/#{pinned_node}/bin:" \
          "#{install_root}/agent-clis/bin:#{install_root}/tools/mise/#{mise_version}/bin:" \
          "#{install_root}/tools/mysql-client/#{mysql_version}/bin:" \
          "#{install_root}/tools/xcodegen/#{xcodegen}/bin:" \
          "#{install_root}/tools/playwright/#{playwright}-mcp-#{playwright_mcp}/bin:/usr/bin:/bin:/usr/sbin:/sbin "
        )
        expect(stdout).not_to include("/opt/homebrew")
        # The agent CLIs are installed with the pinned Node into a Syrus-owned
        # prefix, not Homebrew's global one.
        expect(stdout).to match(%r{#{Regexp.escape(install_root)}/nodes/#{pinned_node}/bin/npm install -g --prefix #{Regexp.escape(install_root)}/agent-clis @anthropic-ai/claude-code@[\d.]+ @openai/codex@[\d.]+})
        expect(stdout).to include("BUNDLE_PATH=#{install_root}/shared/bundles/ruby-#{pinned_ruby}-mysql-#{mysql_version}")
        expect(stdout).to include("install -o root -g wheel -m 644 #{release_path}/bin/macos-runtime-env /usr/local/libexec/syrus/macos-runtime-env")
      end
    end
  end

  # Regression: BSD mv follows a destination symlink to a directory, so
  # `mv -f current.next current` moved the new link inside the previous
  # release and the host kept running the old code.
  it "replaces an existing current symlink on activation", if: RUBY_PLATFORM.include?("darwin") do
    Dir.mktmpdir do |dir|
      old_release = File.join(dir, "releases", "old")
      new_release = File.join(dir, "releases", "new")
      FileUtils.mkdir_p([ old_release, new_release ])
      current = File.join(dir, "current")
      File.symlink(old_release, current)
      activation = File.read(script)[/^run ln -sfn .*current\.next"\nrun mv .*$/]
      expect(activation).not_to be_nil
      commands = activation.gsub(/^run /, "")
        .gsub('"$RELEASE_PATH"', new_release.shellescape)
        .gsub("$INSTALL_ROOT", dir)

      _stdout, stderr, status = Open3.capture3("bash", "-c", commands)

      expect(status).to be_success, stderr
      expect(File.readlink(current)).to eq(new_release)
      expect(File).not_to exist(File.join(old_release, "current.next"))
    end
  end
end
