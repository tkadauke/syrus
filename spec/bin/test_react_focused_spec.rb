# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/test-react-focused", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/test-react-focused") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def git!(dir, *args)
    _out, err, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?
  end

  def write_file(dir, relative_path, content = "")
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Builds a repo with a `main` branch and a checked-out `feature` branch
  # one commit ahead, so `main...HEAD` reflects exactly the feature
  # commit's changes.
  def build_repo(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.email", "test@example.com")
    git!(dir, "config", "user.name", "Test")
    git!(dir, "config", "commit.gpgsign", "false")

    write_file(dir, "README.md", "base\n")
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "-m", "base")

    git!(dir, "checkout", "-q", "-b", "feature")
    yield dir if block_given?
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "-m", "feature work")
  end

  # `node_modules/.package-lock.json` newer than both package manifests --
  # the freshness check bin/test-react-focused reuses verbatim treats this
  # as "already installed."
  def mark_node_modules_fresh(dir)
    write_file(dir, "package.json", "{}")
    write_file(dir, "package-lock.json", "{}")
    FileUtils.mkdir_p(File.join(dir, "node_modules/.bin"))
    write_file(dir, "node_modules/.package-lock.json", "{}")
    future = Time.now + 10
    File.utime(future, future, File.join(dir, "node_modules/.package-lock.json"))
  end

  def run_script(dir)
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.cp(script, File.join(bin_dir, "test-react-focused"))

    write_stub(File.join(bin_dir, "npx"), <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> npx-calls.log
    BASH

    write_stub(File.join(bin_dir, "npm"), <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> npm-calls.log
      mkdir -p node_modules/.bin
      printf '{}' > node_modules/.package-lock.json
    BASH

    Open3.capture3(
      { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}", "HOME" => ENV.fetch("HOME") },
      "bash",
      File.join(bin_dir, "test-react-focused"),
      chdir: dir,
      unsetenv_others: true
    )
  end

  it "runs vitest related only for changed .ts/.tsx files under watched directories" do
    Dir.mktmpdir do |dir|
      mark_node_modules_fresh(dir)
      build_repo(dir) do
        write_file(dir, "app/frontend/routes/Foo.tsx", "export {}\n")
        write_file(dir, "app/frontend/hooks/useFoo.ts", "export {}\n")
        write_file(dir, "plugins/bar/app/frontend/Baz.tsx", "export {}\n")
        write_file(dir, "desktop/src/main.ts", "export {}\n")
        # Should be excluded: non-ts/tsx under a watched dir, and a ts file
        # outside any watched dir.
        write_file(dir, "app/frontend/styles.css", "body {}\n")
        write_file(dir, "app/models/job.rb", "class Job; end\n")
        write_file(dir, "unrelated/other.ts", "export {}\n")
      end

      stdout, stderr, status = run_script(dir)
      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"

      npx_log = File.join(dir, "npx-calls.log")
      expect(File.exist?(npx_log)).to be(true)
      call = File.read(npx_log).lines.first.chomp

      expect(call).to start_with("vitest related --run --passWithNoTests")
      expect(call).to include("--reporter=junit")
      expect(call).to include("--outputFile.junit=.syrus/grade-output/react-tests-focused-junit.xml")

      passed_files = call.split.reject { |a| a.start_with?("-") || %w[vitest related].include?(a) }
      expect(passed_files).to contain_exactly(
        "app/frontend/routes/Foo.tsx",
        "app/frontend/hooks/useFoo.ts",
        "plugins/bar/app/frontend/Baz.tsx",
        "desktop/src/main.ts"
      )

      expect(File.exist?(File.join(dir, "npm-calls.log"))).to be(false)
    end
  end

  it "exits 0 without invoking npx or npm when no watched .ts/.tsx files changed" do
    Dir.mktmpdir do |dir|
      mark_node_modules_fresh(dir)
      build_repo(dir) do
        write_file(dir, "app/frontend/styles.css", "body {}\n")
        write_file(dir, "app/models/job.rb", "class Job; end\n")
      end

      stdout, stderr, status = run_script(dir)
      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("no changed .ts/.tsx files")
      expect(File.exist?(File.join(dir, "npx-calls.log"))).to be(false)
      expect(File.exist?(File.join(dir, "npm-calls.log"))).to be(false)
    end
  end

  it "installs node_modules first when stale, then runs vitest related" do
    Dir.mktmpdir do |dir|
      # No mark_node_modules_fresh: node_modules is entirely absent, so the
      # reused freshness check must trigger an install.
      write_file(dir, "package.json", "{}")
      write_file(dir, "package-lock.json", "{}")
      build_repo(dir) do
        write_file(dir, "app/frontend/routes/Foo.tsx", "export {}\n")
      end

      stdout, stderr, status = run_script(dir)
      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"

      npm_log = File.join(dir, "npm-calls.log")
      expect(File.exist?(npm_log)).to be(true)
      expect(File.read(npm_log)).to include("ci")

      npx_log = File.join(dir, "npx-calls.log")
      expect(File.exist?(npx_log)).to be(true)
      expect(File.read(npx_log).lines.first).to include("app/frontend/routes/Foo.tsx")
    end
  end
end
