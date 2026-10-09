# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/rspec-worker" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/rspec-worker") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  it "excludes specs owned by dedicated graders from the default worker pass" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-worker"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rspec"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rspec args=%s\\n' "$*" >> calls.log
      BASH

      # The typed RSpec CI variant's second phase is solely responsible for
      # running :ci_only specs. The work-engine simulation grader owns the
      # scenario assertion suite. Keep both out of the default parallel pass.
      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME"), "CI" => "true" },
        "bash",
        File.join(bin_dir, "rspec-worker"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.read(log_path).lines.map(&:chomp)).to eq([
        "rspec args=--tag ~ci_only --tag ~work_engine_simulation_assertions --require rspec_junit_formatter --format progress --format json --out .syrus/rspec-json/rspec-1.json --format RspecJunitFormatter --out .syrus/rspec-junit/rspec-junit-1.xml spec/models/job_spec.rb"
      ])
    end
  end

  it "accepts typed-grader tag and output configuration from the environment" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-worker"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rspec"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rspec args=%s\\n' "$*" >> calls.log
      BASH

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}",
          "HOME" => ENV.fetch("HOME"),
          "TEST_ENV_NUMBER" => "3",
          "RSPEC_TAG_ARGS" => "--tag models --tag ~slow",
          "RSPEC_OUTPUT_PREFIX" => "ruby-specs",
          "RSPEC_JUNIT_PREFIX" => "ruby-specs-junit"
        },
        "bash",
        File.join(bin_dir, "rspec-worker"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.read(log_path).lines.map(&:chomp)).to eq([
        "rspec args=--tag models --tag ~slow --require rspec_junit_formatter --format progress --format json --out .syrus/rspec-json/ruby-specs-3.json --format RspecJunitFormatter --out .syrus/rspec-junit/ruby-specs-junit-3.xml spec/models/job_spec.rb"
      ])
    end
  end
end
