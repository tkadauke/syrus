# frozen_string_literal: true

require "open3"
require "rexml/document"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/rspec-ci" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/rspec-ci") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  it "takes the shared rspec-fast lock before preparing test databases" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-ci"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rails"), <<~BASH)
        #!/usr/bin/env bash
        if [ "$RSPEC_FAST_LOCK_HELD" != "1" ]; then
          printf 'rails-before-lock\\n' >> calls.log
          exit 9
        fi
        printf 'rails RAILS_ENV=%s args=%s\\n' "$RAILS_ENV" "$*" >> calls.log
      BASH

      write_stub(File.join(bin_dir, "rspec-fast"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rspec-fast RAILS_ENV=%s COVERAGE=%s RSPEC_FAST_LOCK_HELD=%s args=%s\\n' "$RAILS_ENV" "$COVERAGE" "$RSPEC_FAST_LOCK_HELD" "$*" >> calls.log
      BASH

      write_stub(File.join(bin_dir, "rspec"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rspec RUN_CI_ONLY_SPECS=%s RSPEC_JSON_DIR=%s args=%s\\n' "$RUN_CI_ONLY_SPECS" "$RSPEC_JSON_DIR" "$*" >> calls.log
      BASH

      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash",
        File.join(bin_dir, "rspec-ci"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.read(log_path).lines.map(&:chomp)).to eq([
        "rails RAILS_ENV=test args=db:test:prepare",
        "rspec-fast RAILS_ENV=test COVERAGE=false RSPEC_FAST_LOCK_HELD=1 args=spec/models/job_spec.rb",
        "rspec RUN_CI_ONLY_SPECS=true RSPEC_JSON_DIR=.syrus/rspec-json args=--tag ci_only --require rspec_junit_formatter --format progress --format json --out .syrus/rspec-json/rspec-ci-only.json --format RspecJunitFormatter --out .syrus/rspec-junit/rspec-junit-ci-only.xml spec/models/job_spec.rb"
      ])
    end
  end

  it "refuses to prepare databases while another rspec-fast run holds the lock" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-ci"))
      FileUtils.mkdir_p(File.join(dir, ".syrus"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rails"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rails should not run\\n' >> calls.log
      BASH

      write_stub(File.join(bin_dir, "rspec-fast"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rspec-fast should not run\\n' >> calls.log
      BASH

      lock = File.open(File.join(dir, ".syrus/rspec-fast.lock"), "w")
      expect(lock.flock(File::LOCK_EX | File::LOCK_NB)).to be_truthy

      _stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        File.join(bin_dir, "rspec-ci"),
        chdir: dir,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("Another bin/rspec-fast run is already active")
      expect(File.exist?(log_path)).to be(false)
    ensure
      lock&.close
    end
  end

  it "preserves a failing ci_only exit while merging ci_only JUnit into the grader output" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-ci"))

      write_stub(File.join(bin_dir, "rails"), <<~BASH)
        #!/usr/bin/env bash
        exit 0
      BASH

      write_stub(File.join(bin_dir, "rspec-fast"), <<~BASH)
        #!/usr/bin/env bash
        mkdir -p .syrus/rspec-junit .syrus/grade-output
        printf '<testsuites><testsuite name="parallel" tests="1" failures="0" errors="0" skipped="0" time="0.1"/></testsuites>' > .syrus/rspec-junit/rspec-junit-1.xml
        printf '<testsuites><testsuite name="parallel" tests="1" failures="0" errors="0" skipped="0" time="0.1"/></testsuites>' > .syrus/grade-output/rspec-junit.xml
      BASH

      write_stub(File.join(bin_dir, "rspec"), <<~BASH)
        #!/usr/bin/env bash
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--out" ] && [ "${2:-}" = ".syrus/rspec-junit/rspec-junit-ci-only.xml" ]; then
            mkdir -p "$(dirname "$2")"
            printf '<testsuite name="ci-only" tests="1" failures="1" errors="0" skipped="0" time="0.2"><testcase classname="CiOnly" name="fails"><failure message="boom"/></testcase></testsuite>' > "$2"
          fi
          shift
        done
        exit 7
      BASH

      _stdout, _stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME") },
        "bash",
        File.join(bin_dir, "rspec-ci"),
        chdir: dir,
        unsetenv_others: true
      )

      expect(status.exitstatus).to eq(7)
      merged = File.read(File.join(dir, ".syrus/grade-output/rspec-junit.xml"))
      expect(merged).to include("parallel")
      expect(merged).to include("ci-only")
      expect(REXML::Document.new(merged).root.attributes["failures"]).to eq("1")
    end
  end
end
