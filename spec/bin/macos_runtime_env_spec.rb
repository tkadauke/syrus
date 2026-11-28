# frozen_string_literal: true

require "digest"
require "open3"
require "tmpdir"
require "spec_helper"

# The browser tools a Mac worker installs for itself: `playwright-mcp`, which
# the browser MCP tools and visual review spawn, and Playwright's headless
# Chromium shell. Regression: Mac workers had neither, so every visual review
# there failed with "No such file or directory - playwright-mcp".
RSpec.describe "macOS worker browser tools" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:helper) { File.join(root, "bin/macos-runtime-env") }
  let(:toolchain) { File.read(File.join(root, "config/macos_worker_toolchain.env")) }
  let(:playwright) { toolchain[/^PLAYWRIGHT_VERSION=(.+)$/, 1] }
  let(:playwright_mcp) { toolchain[/^PLAYWRIGHT_MCP_VERSION=(.+)$/, 1] }
  let(:pinned_node) { File.read(File.join(root, ".node-version")).strip }

  def write_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o755, path)
  end

  # Stands in for the pinned Node's npm and for the Playwright CLI npm
  # installs: npm "installs" the packages it is asked for into --prefix, and
  # `playwright install --only-shell chromium` drops the headless shell into
  # PLAYWRIGHT_BROWSERS_PATH (unless told not to). Full Chromium is refused:
  # under a launchd daemon it cannot start (see bin/macos-runtime-env).
  def install_fake_node(dir, chromium: true)
    log = File.join(dir, "npm.log")
    bin = File.join(dir, "nodes", pinned_node, "bin")
    write_executable(File.join(bin, "npm"), <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> #{log.inspect}
      prefix=""; packages=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          install|-g) shift ;;
          --prefix) prefix="$2"; shift 2 ;;
          *) packages+=("$1"); shift ;;
        esac
      done
      for spec in "${packages[@]}"; do
        name="${spec%@*}"; version="${spec##*@}"
        mkdir -p "$prefix/lib/node_modules/$name"
        printf '{\\n  "name": "%s",\\n  "version": "%s"\\n}\\n' "$name" "$version" > "$prefix/lib/node_modules/$name/package.json"
      done
      mkdir -p "$prefix/bin"
      printf '#!/usr/bin/env bash\\nexit 0\\n' > "$prefix/bin/playwright-mcp"
      cat > "$prefix/bin/playwright" <<'PLAYWRIGHT'
      #!/usr/bin/env bash
      [[ "$*" == "install --only-shell chromium" ]] || exit 2
      #{chromium ? "" : "exit 0"}
      shell="$PLAYWRIGHT_BROWSERS_PATH/chromium_headless_shell-1/chrome-headless-shell-mac-arm64/chrome-headless-shell"
      mkdir -p "$(dirname "$shell")"
      printf '#!/usr/bin/env bash\\nexit 0\\n' > "$shell"
      chmod 755 "$shell"
      PLAYWRIGHT
      chmod 755 "$prefix/bin/playwright-mcp" "$prefix/bin/playwright"
    BASH
    write_executable(File.join(bin, "node"), "#!/usr/bin/env bash\necho v#{pinned_node}\n")
    log
  end

  def run_helper(dir, script)
    Open3.capture3(
      { "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "HOME" => dir,
        "SYRUS_MACOS_NODES_ROOT" => File.join(dir, "nodes"), "SYRUS_MACOS_TOOLS_ROOT" => File.join(dir, "tools") },
      "bash", "-c", "source #{helper.inspect} && #{script}", "bash", root,
      unsetenv_others: true
    )
  end

  it "pins the Playwright and @playwright/mcp versions the Linux image installs" do
    dockerfile = File.read(File.join(root, "Dockerfile"))

    expect(playwright).to eq(dockerfile[/^ARG PLAYWRIGHT_VERSION=(.+)$/, 1])
    expect(playwright_mcp).to eq(dockerfile[/^ARG PLAYWRIGHT_MCP_VERSION=(.+)$/, 1])
  end

  it "installs playwright-mcp and the headless Chromium shell with the pinned Node into a versioned prefix, once" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      npm_log = install_fake_node(dir)

      2.times do
        stdout, stderr, status = run_helper(dir, 'syrus_macos_browser_tools_install "$1" && syrus_macos_browser_env "$1"')
        expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"

        prefix = File.join(dir, "tools", "playwright", "#{playwright}-mcp-#{playwright_mcp}")
        expect(stdout).to eq(
          # The binary's own path, not the link: Chromium started through a
          # symlink cannot find its framework and exits.
          "SYRUS_BROWSER_EXECUTABLE_PATH=#{prefix}/ms-playwright/chromium_headless_shell-1/chrome-headless-shell-mac-arm64/chrome-headless-shell\n" \
          "PLAYWRIGHT_BROWSERS_PATH=#{prefix}/ms-playwright\n"
        )
        expect(File).to be_executable(File.join(prefix, "bin", "playwright-mcp"))
        # Relative, so the prefix still works after it is moved into place.
        expect(File.readlink(File.join(prefix, "chromium-headless-shell")))
          .to eq("ms-playwright/chromium_headless_shell-1/chrome-headless-shell-mac-arm64/chrome-headless-shell")
        expect(File).to be_executable(File.join(prefix, "chromium-headless-shell"))
      end
      # The second run finds the pinned versions in place and installs nothing.
      npm_calls = File.readlines(npm_log, chomp: true)
      expect(npm_calls.length).to eq(1)
      expect(npm_calls.first).to match(/\Ainstall -g --prefix \S+ playwright@#{Regexp.escape(playwright)} @playwright\/mcp@#{Regexp.escape(playwright_mcp)}\z/)
    end
  end

  it "leaves nothing in place when Playwright did not install the headless shell" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      install_fake_node(dir, chromium: false)

      _stdout, stderr, status = run_helper(dir, 'syrus_macos_browser_tools_install "$1"')

      expect(status).not_to be_success
      expect(stderr).to include("installed no headless Chromium shell")
      expect(Dir.exist?(File.join(dir, "tools", "playwright"))).to be(false)
    end
  end

  # XcodeGen comes from its GitHub release archive, pinned by URL and SHA-256.
  # A fake curl serves a fake archive, and the release under test pins that
  # archive's checksum.
  def xcodegen_release(dir, archive_sha256:)
    release = File.join(dir, "release")
    FileUtils.mkdir_p(File.join(release, "config"))
    FileUtils.cp([ File.join(root, ".ruby-version"), File.join(root, ".node-version") ], release)
    File.write(File.join(release, "config/macos_worker_toolchain.env"), <<~ENV)
      XCODEGEN_VERSION=9.9.9
      XCODEGEN_URL=https://github.com/yonaskolb/XcodeGen/releases/download/9.9.9/xcodegen.zip
      XCODEGEN_SHA256=#{archive_sha256}
    ENV
    release
  end

  def fake_xcodegen_archive(dir)
    staging = File.join(dir, "archive")
    write_executable(File.join(staging, "xcodegen", "bin", "xcodegen"), "#!/usr/bin/env bash\necho Version: 9.9.9\n")
    FileUtils.mkdir_p(File.join(staging, "xcodegen", "share", "xcodegen", "SettingPresets"))
    archive = File.join(dir, "xcodegen.zip")
    _out, err, status = Open3.capture3("zip", "-qr", archive, "xcodegen", chdir: staging)
    raise err unless status.success?
    archive
  end

  def fake_curl(dir, archive)
    log = File.join(dir, "curl.log")
    write_executable(File.join(dir, "fake-bin", "curl"), <<~BASH)
      #!/usr/bin/env bash
      dest=""
      while [[ $# -gt 0 ]]; do
        case "$1" in -o) dest="$2"; shift 2 ;; *) url="$1"; shift ;; esac
      done
      printf '%s\n' "$url" >> #{log.inspect}
      cp #{archive.inspect} "$dest"
    BASH
    log
  end

  def install_xcodegen(dir, release)
    Open3.capture3(
      { "PATH" => "#{File.join(dir, "fake-bin")}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME" => dir,
        "SYRUS_MACOS_TOOLS_ROOT" => File.join(dir, "tools") },
      "bash", "-c", "source #{helper.inspect} && syrus_macos_xcodegen_install \"$1\"", "bash", release,
      unsetenv_others: true
    )
  end

  it "installs XcodeGen from its pinned release archive with the presets it reads, once" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      archive = fake_xcodegen_archive(dir)
      curl_log = fake_curl(dir, archive)
      release = xcodegen_release(dir, archive_sha256: Digest::SHA256.file(archive).hexdigest)

      2.times do
        stdout, stderr, status = install_xcodegen(dir, release)
        expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      end

      prefix = File.join(dir, "tools", "xcodegen", "9.9.9")
      expect(File).to be_executable(File.join(prefix, "bin", "xcodegen"))
      # XcodeGen finds its SettingPresets relative to its own binary.
      expect(Dir.exist?(File.join(prefix, "share", "xcodegen", "SettingPresets"))).to be(true)
      expect(File.readlines(curl_log, chomp: true))
        .to eq([ "https://github.com/yonaskolb/XcodeGen/releases/download/9.9.9/xcodegen.zip" ])
    end
  end

  it "installs nothing from an XcodeGen archive that does not match its pinned checksum" do
    Dir.mktmpdir do |raw_dir|
      dir = File.realpath(raw_dir)
      fake_curl(dir, fake_xcodegen_archive(dir))
      release = xcodegen_release(dir, archive_sha256: "0" * 64)

      _stdout, stderr, status = install_xcodegen(dir, release)

      expect(status).not_to be_success
      expect(stderr).to include("expected #{"0" * 64}")
      expect(Dir.exist?(File.join(dir, "tools", "xcodegen"))).to be(false)
    end
  end

  it "puts XcodeGen on the runtime PATH that workflow steps inherit" do
    Dir.mktmpdir do |dir|
      stdout, _stderr, status = run_helper(dir, 'syrus_macos_runtime_path "$1"')

      expect(status).to be_success
      expect(stdout.strip.split(":"))
        .to include(File.join(dir, "tools", "xcodegen", toolchain[/^XCODEGEN_VERSION=(.+)$/, 1], "bin"))
    end
  end

  it "puts playwright-mcp on the runtime PATH" do
    Dir.mktmpdir do |dir|
      stdout, _stderr, status = run_helper(dir, 'syrus_macos_runtime_path "$1"')

      expect(status).to be_success
      expect(stdout.strip.split(":").last).to eq(File.join(dir, "tools", "playwright", "#{playwright}-mcp-#{playwright_mcp}", "bin"))
    end
  end
end
