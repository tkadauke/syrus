# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/test-e2e" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/test-e2e") }

  def write_executable(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def run_script(exit_status: 0, remote: false, interrupt: false)
    Dir.mktmpdir("test-e2e-wrapper") do |dir|
      FileUtils.cp(script, File.join(dir, "test-e2e"))
      File.write(File.join(dir, "package.json"), "{}")
      File.write(File.join(dir, "package-lock.json"), "{}")
      FileUtils.mkdir_p(File.join(dir, "node_modules/.bin"))
      lock = File.join(dir, "node_modules/.package-lock.json")
      File.write(lock, "{}")
      future = Time.now + 10
      File.utime(future, future, lock)

      stub_bin = File.join(dir, "stub-bin")
      FileUtils.mkdir_p(stub_bin)
      write_executable(File.join(stub_bin, "node"), <<~BASH)
        #!/usr/bin/env bash
        case "$*" in
          *chromium-headless-shell*) printf chromium_headless_shell-1 ;;
          *) printf chromium-1 ;;
        esac
      BASH
      write_executable(File.join(stub_bin, "npx"), <<~BASH)
        #!/usr/bin/env bash
        printf '%s' "$SYRUS_DATA_ROOT" > e2e-data-root.log
        mkdir -p "$SYRUS_DATA_ROOT/clones"
        touch "$SYRUS_DATA_ROOT/clones/fixture.git"
        #{'kill -TERM "$PPID"' if interrupt}
        exit #{exit_status}
      BASH

      browser_root = File.join(dir, "browsers")
      FileUtils.mkdir_p(File.join(browser_root, "chromium-1/chrome-linux64"))
      FileUtils.mkdir_p(File.join(browser_root, "chromium_headless_shell-1/chrome-headless-shell-linux64"))
      FileUtils.touch(File.join(browser_root, "chromium-1/chrome-linux64/chrome"))
      FileUtils.touch(File.join(browser_root, "chromium_headless_shell-1/chrome-headless-shell-linux64/chrome-headless-shell"))
      FileUtils.chmod(0o755, Dir[File.join(browser_root, "**/chrome*")])

      caller_root = File.join(dir, "operator-data")
      FileUtils.mkdir_p(File.join(caller_root, "clones"))
      sentinel = File.join(caller_root, "clones/live.git")
      File.write(sentinel, "untouched")

      env = {
          "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}",
          "HOME" => dir,
          "PLAYWRIGHT_BROWSERS_PATH" => browser_root,
          "SYRUS_DATA_ROOT" => caller_root,
          "E2E_SKIP_SEED" => "1"
      }
      env["E2E_BASE_URL"] = "https://example.test" if remote
      stdout, stderr, status = Open3.capture3(
        env,
        "bash", File.join(dir, "test-e2e"),
        chdir: dir,
        unsetenv_others: true
      )

      isolated_root = File.read(File.join(dir, "e2e-data-root.log"))
      yield(status, stdout, stderr, caller_root, sentinel, isolated_root)
    end
  end

  it "uses and cleans a disposable data root without touching the caller's root" do
    run_script do |status, stdout, stderr, caller_root, sentinel, isolated_root|
      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(isolated_root).not_to eq(caller_root)
      expect(File.exist?(isolated_root)).to be(false)
      expect(File.read(sentinel)).to eq("untouched")
    end
  end

  it "cleans the disposable data root when Playwright fails" do
    run_script(exit_status: 7) do |status, _stdout, _stderr, _caller_root, _sentinel, isolated_root|
      expect(status.exitstatus).to eq(7)
      expect(File.exist?(isolated_root)).to be(false)
    end
  end

  it "cleans the disposable data root when interrupted" do
    run_script(interrupt: true) do |status, _stdout, _stderr, _caller_root, _sentinel, isolated_root|
      expect(status.exitstatus).to eq(143)
      expect(File.exist?(isolated_root)).to be(false)
    end
  end

  it "preserves the caller's data root for remote E2E runs" do
    run_script(remote: true) do |status, stdout, stderr, caller_root, sentinel, observed_root|
      expect(status).to be_success, "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(observed_root).to eq(caller_root)
      expect(File.read(sentinel)).to eq("untouched")
      expect(File.exist?(File.join(caller_root, "clones/fixture.git"))).to be(true)
    end
  end
end
