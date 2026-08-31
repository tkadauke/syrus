# frozen_string_literal: true

require "open3"
require "rexml/document"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/rspec-fast", :ci_only do
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
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME"), "RSPEC_PROCESSES" => "8" },
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
        "bundle-exec command=parallel_rspec RUN_CI_ONLY_SPECS=false args=parallel_rspec -n 8 --quiet --runtime-log .syrus/parallel_runtime_rspec.log --exec-args bin/rspec-worker spec/models/job_spec.rb"
      ])
    end
  end

  # Each parallel worker writes its own JUnit document covering only its slice
  # of the suite, so ingesting one of them would silently record a fraction of
  # the run. bin/rspec-fast merges them into the single path the rspec grader
  # declares as `junit_output:`.
  it "merges per-worker JUnit documents into one testsuites file" do
    Dir.mktmpdir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.cp(script, File.join(bin_dir, "rspec-fast"))

      write_stub(File.join(bin_dir, "rails"), "#!/usr/bin/env bash\nexit 0\n")
      # Stand in for parallel_rspec: emit two per-worker documents the way the
      # real workers would.
      write_stub(File.join(bin_dir, "bundle"), <<~BASH)
        #!/usr/bin/env bash
        if [ "$2" = "parallel_rspec" ]; then
          mkdir -p "$RSPEC_JUNIT_DIR"
          printf '%s' "<testsuite name='rspec' tests='2' failures='1' errors='0' skipped='0' time='1.5'><testcase name='a'/><testcase name='b'/></testsuite>" > "$RSPEC_JUNIT_DIR/rspec-junit-1.xml"
          printf '%s' "<testsuite name='rspec' tests='3' failures='0' errors='0' skipped='1' time='2.5'><testcase name='c'/></testsuite>" > "$RSPEC_JUNIT_DIR/rspec-junit-2.xml"
        fi
        exit 0
      BASH

      _stdout, _stderr, status = Open3.capture3(
        { "PATH" => "#{bin_dir}:#{ENV.fetch("PATH")}", "HOME" => ENV.fetch("HOME") },
        "bash",
        File.join(bin_dir, "rspec-fast"),
        "spec/models/job_spec.rb",
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success
      merged = File.read(File.join(dir, ".syrus/grade-output/rspec-junit.xml"))
      doc = REXML::Document.new(merged)

      expect(doc.root.name).to eq("testsuites")
      expect(doc.root.elements.to_a("testsuite").size).to eq(2)
      # Totals are summed across workers, not taken from whichever file was last.
      expect(doc.root.attributes["tests"]).to eq("5")
      expect(doc.root.attributes["failures"]).to eq("1")
      expect(doc.root.attributes["skipped"]).to eq("1")
      # JunitXmlParser reads a <testsuites> wrapper, which is why the merge
      # produces one; it is exercised against Rails in the parser's own spec.
      expect(doc.root.elements.to_a("testsuite/testcase").size).to eq(3)
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
