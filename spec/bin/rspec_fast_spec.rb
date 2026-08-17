# frozen_string_literal: true

require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/rspec-fast" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/rspec-fast") }

  def write_stub(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  it "prepares the test database before preparing and running the parallel suite" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-fast"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rails"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rails RAILS_ENV=%s args=%s\\n' "$RAILS_ENV" "$*" >> calls.log
      BASH

      write_stub(File.join(bin_dir, "bundle"), <<~BASH)
        #!/usr/bin/env bash
        shift
        printf 'bundle-exec command=%s RUN_CI_ONLY_SPECS=%s args=%s\\n' "$1" "$RUN_CI_ONLY_SPECS" "$*" >> calls.log
      BASH

      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        File.join(bin_dir, "rspec-fast"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(File.read(log_path).lines.map(&:chomp)).to eq([
        "rails RAILS_ENV=test args=db:test:prepare",
        "bundle-exec command=rake RUN_CI_ONLY_SPECS=false args=rake parallel:prepare",
        "bundle-exec command=parallel_rspec RUN_CI_ONLY_SPECS=false args=parallel_rspec -n 8 --quiet --exec-args bin/rspec-worker spec/models/job_spec.rb"
      ])
    end
  end

  it "forces RUN_CI_ONLY_SPECS=false even when the ambient environment sets CI=true" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-fast"))
      log_path = File.join(dir, "calls.log")

      write_stub(File.join(bin_dir, "rails"), <<~BASH)
        #!/usr/bin/env bash
        printf 'rails RAILS_ENV=%s args=%s\\n' "$RAILS_ENV" "$*" >> calls.log
      BASH

      write_stub(File.join(bin_dir, "bundle"), <<~BASH)
        #!/usr/bin/env bash
        shift
        printf 'bundle-exec command=%s RUN_CI_ONLY_SPECS=%s\\n' "$1" "$RUN_CI_ONLY_SPECS" >> calls.log
      BASH

      # GitHub Actions sets CI=true on every job. The parallel main pass must
      # still exclude :ci_only specs (they run in bin/rspec-ci's dedicated
      # serial pass instead) or a schema-mutating migration spec can corrupt
      # a shared parallel worker process for every spec that runs after it.
      stdout, stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME"), "CI" => "true" },
        "bash",
        File.join(bin_dir, "rspec-fast"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      bundle_lines = File.read(log_path).lines.map(&:chomp).grep(/^bundle-exec/)
      expect(bundle_lines).to all(match(/RUN_CI_ONLY_SPECS=false\z/))
    end
  end
end
