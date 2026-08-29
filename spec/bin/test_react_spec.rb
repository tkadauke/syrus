# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/test-react" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/test-react") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  def mark_node_modules_fresh(dir)
    File.write(File.join(dir, "package.json"), "{}")
    File.write(File.join(dir, "package-lock.json"), "{}")
    FileUtils.mkdir_p(File.join(dir, "node_modules/.bin"))
    File.write(File.join(dir, "node_modules/.package-lock.json"), "{}")
    future = Time.now + 10
    File.utime(future, future, File.join(dir, "node_modules/.package-lock.json"))
  end

  def run_script(dir, env = {})
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.cp(script, File.join(bin_dir, "test-react"))

    write_stub(File.join(bin_dir, "npx"), <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> npx-calls.log
    BASH

    write_stub(File.join(bin_dir, "npm"), <<~BASH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> npm-calls.log
    BASH

    Open3.capture3(
      env.merge("PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}", "HOME" => ENV.fetch("HOME")),
      "bash",
      File.join(bin_dir, "test-react"),
      chdir: dir,
      unsetenv_others: true
    )
  end

  it "defaults Vitest to two workers for shared grader hosts" do
    Dir.mktmpdir do |dir|
      mark_node_modules_fresh(dir)

      stdout, stderr, status = run_script(dir)
      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"

      expect(File.read(File.join(dir, "npx-calls.log"))).to include("vitest run --coverage --maxWorkers 2")
      expect(File.read(File.join(dir, "npm-calls.log"))).to include("run typecheck")
      expect(File.read(File.join(dir, "npm-calls.log"))).to include("run lint")
    end
  end

  it "allows callers to override the Vitest worker count" do
    Dir.mktmpdir do |dir|
      mark_node_modules_fresh(dir)

      stdout, stderr, status = run_script(dir, "VITEST_MAX_WORKERS" => "3")
      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"

      expect(File.read(File.join(dir, "npx-calls.log"))).to include("vitest run --coverage --maxWorkers 3")
    end
  end
end
