# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/rspec-focused", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/rspec-focused") }

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

  # Builds a repo with a `main` branch (with fixture spec files already
  # present) and a checked-out `feature` branch one commit ahead, so
  # `main...HEAD` reflects exactly the feature commit's changes.
  def build_repo(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.email", "test@example.com")
    git!(dir, "config", "user.name", "Test")
    git!(dir, "config", "commit.gpgsign", "false")

    write_file(dir, "spec/models/job_spec.rb", "# base fixture\n")
    write_file(dir, "spec/lib/foo_spec.rb", "# base fixture\n")
    write_file(dir, "plugins/foo/spec/bar_spec.rb", "# base fixture\n")
    write_file(dir, "plugins/foo/spec/lib/baz_spec.rb", "# base fixture\n")
    write_file(dir, "README.md", "base\n")
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "-m", "base")

    git!(dir, "checkout", "-q", "-b", "feature")
    yield dir if block_given?
    git!(dir, "add", "-A")
    git!(dir, "commit", "-q", "-m", "feature work")
  end

  def run_script(dir, log_path)
    bin_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.cp(script, File.join(bin_dir, "rspec-focused"))
    write_stub(File.join(bin_dir, "rspec-fast"), <<~BASH)
      #!/usr/bin/env bash
      printf 'rspec-fast RSPEC_JUNIT_OUTPUT=%s args=%s\\n' "$RSPEC_JUNIT_OUTPUT" "$*" >> #{log_path}
    BASH

    Open3.capture3(
      { "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}", "HOME" => ENV.fetch("HOME") },
      "bash",
      File.join(bin_dir, "rspec-focused"),
      chdir: dir,
      unsetenv_others: true
    )
  end

  it "maps changed app/lib/plugin files to their conventional specs and includes a changed spec file directly" do
    Dir.mktmpdir do |dir|
      build_repo(dir) do
        write_file(dir, "app/models/job.rb", "class Job; end\n")
        write_file(dir, "lib/foo.rb", "module Foo; end\n")
        write_file(dir, "plugins/foo/app/bar.rb", "class Bar; end\n")
        write_file(dir, "plugins/foo/lib/baz.rb", "module Baz; end\n")
        write_file(dir, "spec/models/existing_spec.rb", "# changed spec file\n")
        write_file(dir, "app/other.rb", "class Other; end\n") # no spec/other_spec.rb on disk
      end

      log_path = File.join(dir, "calls.log")
      stdout, stderr, status = run_script(dir, log_path)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.exist?(log_path)).to be(true)

      line = File.read(log_path).lines.first.chomp
      expect(line).to include("RSPEC_JUNIT_OUTPUT=.syrus/grade-output/rspec-focused-junit.xml")

      passed_specs = line.sub(/\A.*args=/, "").split
      expect(passed_specs).to contain_exactly(
        "spec/models/job_spec.rb",
        "spec/lib/foo_spec.rb",
        "plugins/foo/spec/bar_spec.rb",
        "plugins/foo/spec/lib/baz_spec.rb",
        "spec/models/existing_spec.rb"
      )
      # No conventional spec exists on disk for app/other.rb, so it must be excluded.
      expect(passed_specs).not_to include("spec/other_spec.rb")
    end
  end

  it "excludes evals/ scenario fixture specs even though they match the spec-file pattern" do
    Dir.mktmpdir do |dir|
      build_repo(dir) do
        write_file(
          dir,
          "evals/scenarios/some_scenario/fixture_repo/spec/services/thing_spec.rb",
          "# minitest fixture, not an rspec spec of this repo\n"
        )
        write_file(dir, "app/models/job.rb", "class Job; end\n")
      end

      log_path = File.join(dir, "calls.log")
      stdout, stderr, status = run_script(dir, log_path)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.exist?(log_path)).to be(true)

      line = File.read(log_path).lines.first.chomp
      passed_specs = line.sub(/\A.*args=/, "").split
      expect(passed_specs).to contain_exactly("spec/models/job_spec.rb")
      expect(passed_specs).not_to include(
        "evals/scenarios/some_scenario/fixture_repo/spec/services/thing_spec.rb"
      )
    end
  end

  it "exits 0 without invoking bin/rspec-fast when no Ruby files changed" do
    Dir.mktmpdir do |dir|
      build_repo(dir) do
        write_file(dir, "README.md", "updated\n")
      end

      log_path = File.join(dir, "calls.log")
      stdout, stderr, status = run_script(dir, log_path)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("no changed Ruby files")
      expect(File.exist?(log_path)).to be(false)
    end
  end

  it "exits 0 without invoking bin/rspec-fast when changed Ruby files have no spec on disk" do
    Dir.mktmpdir do |dir|
      build_repo(dir) do
        write_file(dir, "app/other.rb", "class Other; end\n")
        write_file(dir, "config/routes.rb", "Rails.application.routes.draw {}\n")
      end

      log_path = File.join(dir, "calls.log")
      stdout, stderr, status = run_script(dir, log_path)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("no related specs found")
      expect(File.exist?(log_path)).to be(false)
    end
  end

  it "deduplicates a spec that would otherwise be included twice" do
    Dir.mktmpdir do |dir|
      build_repo(dir) do
        write_file(dir, "app/models/job.rb", "class Job; end\n")
      end
      # Modify the same file again in a second commit on the feature branch --
      # still only one entry in the ACMR diff against main, but this guards
      # against a regression where the mapping logic double-counts.
      write_file(dir, "app/models/job.rb", "class Job; def x; end; end\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-q", "-m", "tweak")

      log_path = File.join(dir, "calls.log")
      stdout, stderr, status = run_script(dir, log_path)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      line = File.read(log_path).lines.first.chomp
      passed_specs = line.sub(/\A.*args=/, "").split
      expect(passed_specs).to eq(["spec/models/job_spec.rb"])
    end
  end
end
