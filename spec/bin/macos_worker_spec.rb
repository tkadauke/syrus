# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "native macOS worker scripts" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:entrypoint) { File.join(root, "bin/macos-worker") }
  let(:check) { File.join(root, "bin/macos-worker-check") }

  let(:pinned_ruby) { File.read(File.join(root, ".ruby-version")).strip }
  let(:pinned_node) { File.read(File.join(root, ".node-version")).strip }
  let(:system_path) { "/usr/bin:/bin:/usr/sbin:/sbin" }

  # The system directories are the grading host's own, and a Linux grader
  # image ships playwright-mcp in /usr/bin. Mirror them without the named
  # tools so a "missing tool" example means the same thing on every host.
  def system_path_without(dir, *tools)
    mirror = File.join(dir, "system-bin")
    FileUtils.mkdir_p(mirror)
    system_path.split(":").each do |source|
      next unless File.directory?(source)

      Dir.each_child(source) do |name|
        target = File.join(mirror, name)
        next if tools.include?(name) || File.exist?(target)

        File.symlink(File.join(source, name), target)
      end
    end
    mirror
  end

  def toolchain_pin(key)
    File.read(File.join(root, "config/macos_worker_toolchain.env"))[/^#{key}=(.+)$/, 1]
  end

  # Homebrew is shared with every account on the host, and upgrades there
  # broke the worker's Ruby, Node, and mysql2. The services start with only
  # the system's own directories; bin/macos-worker adds the pinned toolchain.
  it "starts worker and updater services with nothing from Homebrew or /usr/local" do
    %w[com.syrus.worker.plist com.syrus.updater.plist].each do |name|
      plist = File.read(File.join(root, "config/launchd", name))

      expect(plist).to match(%r{<key>PATH</key>\s*<string>/usr/bin:/bin:/usr/sbin:/sbin</string>})
      expect(plist).not_to include("/opt/homebrew")
      expect(plist).not_to include("/usr/local/bin")
      expect(plist).not_to include("BUNDLE_PATH")
    end
  end

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def write_env(path, overrides = {})
    values = {
      # The fake toolchain with_stubbed_host_bin and install_fake_runtimes
      # create next to the env file.
      "SYRUS_MACOS_TOOLS_ROOT" => File.join(File.dirname(path), "tools"),
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

  # The browser tools as bin/macos-runtime-env installs them: one prefix per
  # pinned Playwright + @playwright/mcp pair, with `chromium-headless-shell` linking into
  # Playwright's browsers directory.
  def install_fake_browser_tools(tools_root)
    playwright = toolchain_pin("PLAYWRIGHT_VERSION")
    mcp = toolchain_pin("PLAYWRIGHT_MCP_VERSION")
    prefix = File.join(tools_root, "playwright", "#{playwright}-mcp-#{mcp}")
    { "playwright" => playwright, "@playwright/mcp" => mcp }.each do |package, version|
      FileUtils.mkdir_p(File.join(prefix, "lib", "node_modules", package))
      File.write(File.join(prefix, "lib", "node_modules", package, "package.json"), %({\n  "name": "#{package}",\n  "version": "#{version}"\n}\n))
    end
    FileUtils.mkdir_p(File.join(prefix, "bin"))
    File.write(File.join(prefix, "bin", "playwright-mcp"), "#!/usr/bin/env bash\nexit 0\n")
    File.chmod(0o755, File.join(prefix, "bin", "playwright-mcp"))
    browser = File.join(prefix, "ms-playwright", "chromium_headless_shell-1", "chrome-headless-shell-mac-arm64", "chrome-headless-shell")
    FileUtils.mkdir_p(File.dirname(browser))
    File.write(browser, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod(0o755, browser)
    File.symlink("ms-playwright/chromium_headless_shell-1/chrome-headless-shell-mac-arm64/chrome-headless-shell",
      File.join(prefix, "chromium-headless-shell"))
    prefix
  end

  # XcodeGen as bin/macos-runtime-env installs it: the release archive's bin/
  # and share/xcodegen, under one prefix per pinned version.
  def install_fake_xcodegen(tools_root)
    version = toolchain_pin("XCODEGEN_VERSION")
    prefix = File.join(tools_root, "xcodegen", version)
    FileUtils.mkdir_p([ File.join(prefix, "bin"), File.join(prefix, "share", "xcodegen", "SettingPresets") ])
    File.write(File.join(prefix, "bin", "xcodegen"), "#!/usr/bin/env bash\necho Version: #{version}\n")
    File.chmod(0o755, File.join(prefix, "bin", "xcodegen"))
    prefix
  end

  def with_stubbed_host_bin(dir, xcode_select_path: "/Applications/Xcode.app/Contents/Developer", ruby_version: pinned_ruby,
                            node_version: pinned_node)
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)

    write_stub(File.join(bin_dir, "uname"), "#!/usr/bin/env bash\necho Darwin\n")
    write_stub(File.join(bin_dir, "ruby"), fake_ruby_body(ruby_version))
    write_stub(File.join(bin_dir, "bundle"), "#!/usr/bin/env bash\necho Bundler version 2.7.2\n")
    write_stub(File.join(bin_dir, "node"), "#!/usr/bin/env bash\necho v#{node_version}\n")
    write_stub(File.join(bin_dir, "npm"), "#!/usr/bin/env bash\necho 11.0.0\n")
    write_stub(File.join(bin_dir, "git"), "#!/usr/bin/env bash\necho git version 2.50.0\n")
    write_stub(File.join(bin_dir, "mise"), "#!/usr/bin/env bash\necho 2026.1.0\n")
    write_stub(File.join(bin_dir, "codex"), "#!/usr/bin/env bash\necho codex-cli 0.160.0\n")
    write_stub(File.join(bin_dir, "claude"), "#!/usr/bin/env bash\necho 2.1.289\n")
    write_stub(File.join(bin_dir, "playwright-mcp"), "#!/usr/bin/env bash\nexit 0\n")
    write_stub(File.join(bin_dir, "xcodegen"), "#!/usr/bin/env bash\necho Version: #{toolchain_pin("XCODEGEN_VERSION")}\n")
    install_fake_browser_tools(File.join(dir, "tools"))
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
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
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
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL Ruby on PATH is 3.4.99, but the release pins #{pinned_ruby}")
    end
  end

  # Regression: as Background jobs the worker and updater ran at the lowest
  # CPU priority with throttled I/O, so another account's Xcode build on the
  # host starved them: heartbeats lapsed and an update took many minutes to
  # unpack a release.
  it "runs the worker and updater at standard priority, not as background jobs" do
    %w[com.syrus.worker.plist com.syrus.updater.plist].each do |name|
      plist = File.read(File.join(root, "config/launchd", name))

      expect(plist).to match(%r{<key>ProcessType</key>\s*<string>Standard</string>})
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
      expect(stdout).to include("NODE=/opt/syrus/nodes/#{pinned_node}/bin/node")
      expect(stdout).to include("AGENT_CLIS=/opt/syrus/agent-clis/bin")
      expect(stdout).to include("BUNDLE_PATH=/opt/syrus/shared/bundles/ruby-#{pinned_ruby}")
      # Keeps libvips out of the worker; see spec/config/libvips_boot_spec.rb.
      expect(stdout).to include("BUNDLE_WITHOUT=images")
      # The browser plugin's settings, pointing at the pinned browser tools
      # rather than the Linux image's /opt/syrus-browser and /opt/ms-playwright.
      expect(stdout).to match(%r{^SYRUS_BROWSER_EXECUTABLE_PATH=.*/tools/playwright/[^/]+/(chromium-headless-shell|ms-playwright/.+/chrome-headless-shell)$})
      expect(stdout).to match(%r{^PLAYWRIGHT_BROWSERS_PATH=.*/tools/playwright/[^/]+/ms-playwright$})
      expect(stdout).not_to include("SYRUS_LIBVIPS")
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

  # The pinned toolchain as the installer leaves it, under temporary roots.
  # SYRUS_MACOS_SYSTEM_PATH keeps the stubbed host commands reachable after
  # activation replaces PATH.
  def install_fake_runtimes(dir, bin_dir, node: true)
    rubies = File.join(dir, "rubies")
    nodes = File.join(dir, "nodes")
    tools = File.join(dir, "tools")
    FileUtils.mkdir_p(File.join(rubies, pinned_ruby, "bin"))
    write_stub(File.join(rubies, pinned_ruby, "bin", "ruby"), fake_ruby_body(pinned_ruby))
    if node
      FileUtils.mkdir_p(File.join(nodes, pinned_node, "bin"))
      write_stub(File.join(nodes, pinned_node, "bin", "node"), "#!/usr/bin/env bash\necho v#{pinned_node}\n")
    end
    mise_bin = File.join(tools, "mise", toolchain_pin("MISE_VERSION"), "bin")
    FileUtils.mkdir_p(mise_bin)
    write_stub(File.join(mise_bin, "mise"), "#!/usr/bin/env bash\necho #{toolchain_pin("MISE_VERSION")} macos-arm64\n")
    mysql = File.join(tools, "mysql-client", toolchain_pin("MYSQL_CLIENT_VERSION"))
    FileUtils.mkdir_p([ File.join(mysql, "bin"), File.join(mysql, "lib") ])
    write_stub(File.join(mysql, "bin", "mysql_config"), "#!/usr/bin/env bash\necho #{toolchain_pin("MYSQL_CLIENT_VERSION")}\n")
    FileUtils.touch(File.join(mysql, "lib", "libmysqlclient.24.dylib"))
    { "SYRUS_MACOS_RUBIES_ROOT" => rubies, "SYRUS_MACOS_NODES_ROOT" => nodes, "SYRUS_MACOS_TOOLS_ROOT" => tools,
      "SYRUS_MACOS_SYSTEM_PATH" => "#{bin_dir}:#{system_path}" }
  end

  it "runs the worker on the pinned Ruby and Node once they are installed" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file, "GIT_SHA" => "abc123")
      # The host's own ruby and node are other versions -- as when another
      # account's Homebrew install changes or breaks them.
      bin_dir = with_stubbed_host_bin(dir, ruby_version: "3.4.99", node_version: "25.0.0")

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") }.merge(install_fake_runtimes(dir, bin_dir)),
        "bash", entrypoint, "--env-file", env_file, "--check",
        unsetenv_others: true
      )

      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("OK   Ruby matches .ruby-version: #{pinned_ruby}")
      expect(stdout).to include("OK   Node matches .node-version: #{pinned_node}")
    end
  end

  # Regression: workflow steps inherit the worker's PATH, and a job's own
  # `bundle install` built mysql2 against Homebrew's mysql_config -- mysql2's
  # extconf falls back to Homebrew's locations when PATH has none -- which no
  # longer linked once the worker left Homebrew, so every prepare step on the
  # Mac failed.
  it "puts the pinned MySQL client's mysql_config first on the PATH that workflow steps inherit" do
    Dir.mktmpdir do |dir|
      bin_dir = with_stubbed_host_bin(dir)
      write_stub(File.join(bin_dir, "mysql_config"), "#!/usr/bin/env bash\necho host\n")
      runtimes = install_fake_runtimes(dir, bin_dir)

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") }.merge(runtimes),
        "bash", "-c",
        'source "$1/bin/macos-runtime-env" && syrus_macos_runtime_activate "$1" "$2" && command -v mysql_config',
        "bash", root, File.join(dir, "shared"),
        unsetenv_others: true
      )

      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout.strip).to eq(
        File.join(runtimes.fetch("SYRUS_MACOS_TOOLS_ROOT"), "mysql-client", toolchain_pin("MYSQL_CLIENT_VERSION"), "bin", "mysql_config")
      )
    end
  end

  # Regression: another account's Homebrew install upgraded a library
  # Homebrew's node@22 linked against, Node aborted at launch, and every npm
  # step on the Mac worker failed.
  it "refuses to start when the pinned Node is not installed instead of using the host's Node" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir)

      _stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") }.merge(install_fake_runtimes(dir, bin_dir, node: false)),
        "bash", entrypoint, "--env-file", env_file, "--check",
        unsetenv_others: true
      )

      expect(status).not_to be_success
      expect(stderr).to include("Node #{pinned_node} (from #{root}/.node-version) is not installed under #{dir}/nodes")
    end
  end

  it "fails validation when the Node on PATH is not the release's pinned Node" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir, node_version: "25.0.0")

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL Node on PATH is v25.0.0, but the release pins #{pinned_node}")
    end
  end

  it "fails validation when Homebrew or /usr/local is on PATH" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir)

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:/opt/homebrew/bin:#{system_path}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL PATH includes shared directories other accounts can change: /opt/homebrew/bin")
    end
  end

  it "pins the Node major version the Linux image installs" do
    node_major = File.read(File.join(root, "Dockerfile"))[/^ARG NODE_MAJOR=(\d+)$/, 1]

    expect(pinned_node).to match(/\A#{node_major}\.\d+\.\d+\z/)
  end

  it "fails validation when the browser tools visual review needs are missing" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir)
      FileUtils.rm(File.join(bin_dir, "playwright-mcp"))
      FileUtils.rm_rf(File.join(dir, "tools", "playwright"))

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path_without(dir, "playwright-mcp")}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("FAIL Playwright MCP: playwright-mcp not found on PATH")
      expect(stdout).to match(%r{FAIL browser Chromium: .*/tools/playwright/[^/]+/chromium-headless-shell is not installed})
      expect(stdout).to include("macos-worker-check: 2 failure(s)")
    end
  end

  # The worker environment smoke checks the worker runs at boot: an essential
  # failure fails the host check, the rest only warn because the worker keeps
  # taking the work that does not need them.
  it "folds the worker environment smoke checks into the host check" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir)
      write_stub(File.join(bin_dir, "ruby"), <<~BASH)
        #!/usr/bin/env bash
        if [[ "$1" == *worker-environment-smoke ]]; then
          echo "OK   git: git version 2.54.0"
          echo "WARN mysql_client: no mysql_config found (work that needs it is routed elsewhere)"
          echo "FAIL workflow_data_root: flock failed on /var/lib/syrus/workflows/.locks: ENOTSUP"
          exit 1
        fi
        #{fake_ruby_body(pinned_ruby).lines.drop(1).join}
      BASH

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
        "bash", check, "--env-file", env_file,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("OK   environment git: git version 2.54.0")
      expect(stdout).to include("WARN environment mysql_client: no mysql_config found")
      expect(stdout).to include("FAIL environment workflow_data_root: flock failed on /var/lib/syrus/workflows/.locks: ENOTSUP")
      expect(stdout).to include("macos-worker-check: 1 failure(s)")
    end
  end

  it "fails validation when only Command Line Tools are selected" do
    Dir.mktmpdir do |dir|
      env_file = File.join(dir, "worker.env")
      write_env(env_file)
      bin_dir = with_stubbed_host_bin(dir, xcode_select_path: "/Library/Developer/CommandLineTools")

      stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
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
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME"),
          "SYRUS_MACOS_TOOLS_ROOT" => File.join(dir, "tools") },
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
        { "PATH" => "#{bin_dir}:#{system_path}", "HOME" => ENV.fetch("HOME") },
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
