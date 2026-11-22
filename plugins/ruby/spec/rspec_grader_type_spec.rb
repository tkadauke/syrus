require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::RspecGraderType do
  def focused_selector_from(command)
    script_arg = command.match(/ruby -e (?<script>.+?) > \.syrus\/rspec-focused-files/m)[:script]
    Shellwords.split(script_arg).sole
  end

  def run_generated_rspec_command(command, parallel_status:, serial_status: 0, extra_env: {})
    Dir.mktmpdir("rspec-grader-command") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      File.write(File.join(bin_dir, "bundle"), <<~BASH)
        #!/usr/bin/env bash
        case "$1" in
          check|install) exit 0 ;;
          exec) shift; "$@"; exit $? ;;
          *) echo "unexpected bundle command: $*" >&2; exit 64 ;;
        esac
      BASH
      File.write(File.join(bin_dir, "parallel_rspec"), <<~BASH)
        #!/usr/bin/env bash
        printf '%s\n' "$*" > parallel_rspec_args.txt
        exit "${FAKE_PARALLEL_RSPEC_STATUS:-0}"
      BASH
      File.write(File.join(bin_dir, "rspec"), <<~BASH)
        #!/usr/bin/env bash
        exit "${FAKE_RSPEC_STATUS:-0}"
      BASH
      FileUtils.chmod("+x", Dir[File.join(bin_dir, "*")])

      env = {
        "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}",
        "FAKE_PARALLEL_RSPEC_STATUS" => parallel_status.to_s,
        "FAKE_RSPEC_STATUS" => serial_status.to_s,
        "BUNDLE_GEMFILE" => nil,
        "GEM_HOME" => nil,
        "GEM_PATH" => nil,
        "RUBYLIB" => nil,
        "RUBYOPT" => nil
      }.merge(extra_env)
      yield dir if block_given?
      stdout, stderr, status = Open3.capture3(env, "bash", "-c", command, chdir: dir)
      parallel_args = File.exist?(File.join(dir, "parallel_rspec_args.txt")) ? File.read(File.join(dir, "parallel_rspec_args.txt")) : ""
      [ stdout, stderr, status, parallel_args ]
    end
  end

  # The serial CI-tag pass ran a quarter of the suite on one core and was the
  # longest part of the CI grader. With serial_paths, CI-only examples join
  # the parallel pass and only the listed paths stay serial.
  describe "CI grader with parallel_rspec.serial_paths" do
    def ci_step(serial_paths: [ "spec/migrations/", "spec/bin/check_spec.rb" ], tags: { "ci" => { "include" => [ "ci_only" ] } })
      described_class.grade_steps(
        config: {
          "tags" => tags,
          "parallel_rspec" => {
            "enabled" => true, "rspec_modes" => [ "ci" ], "exec_args" => "bin/rspec-worker", "serial_paths" => serial_paths
          }
        },
        default_failures: "strict"
      ).third
    end

    it "runs CI-only examples in the parallel pass and keeps only the serial paths serial" do
      _stdout, _stderr, status, parallel_args = run_generated_rspec_command(ci_step.run, parallel_status: 0)

      expect(status).to be_success
      expect(parallel_args).to include("--exclude-pattern", "spec/migrations/|spec/bin/check_spec\\.rb")
      expect(ci_step.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~syrus_no_such_tag RUN_CI_ONLY_SPECS=true")
      expect(ci_step.run).to match(%r{RUN_CI_ONLY_SPECS=true bundle exec rspec .*--tag \\~syrus_no_such_tag spec/migrations/ spec/bin/check_spec\.rb})
      expect(ci_step.run).not_to include("--tag ci_only")
    end

    it "excludes exactly the serial paths from parallel file discovery" do
      pattern = Regexp.new(Shellwords.split(ci_step.run[/--exclude-pattern \S+/]).last)

      expect(pattern).to match("spec/migrations/add_thing_spec.rb")
      expect(pattern).to match("./spec/bin/check_spec.rb")
      expect(pattern).not_to match("spec/models/migration_spec.rb")
      expect(pattern).not_to match("spec/bin/check_spec_rb")
    end

    it "fails when either pass fails" do
      expect(run_generated_rspec_command(ci_step.run, parallel_status: 1)[2]).not_to be_success
      expect(run_generated_rspec_command(ci_step.run, parallel_status: 0, serial_status: 1)[2]).not_to be_success
    end

    it "keeps the separate serial CI-tag pass without serial_paths" do
      run = ci_step(serial_paths: []).run

      expect(run).not_to include("--exclude-pattern")
      expect(run).to include("--tag ci_only")
    end
  end

  # The CI suite was the critical path of nearly every grading pass, an hour
  # on one worker while the rest of the fan-out had finished. Shards split it
  # into disjoint slices that run on different workers at once.
  describe "CI grader shards" do
    def sharded_steps(shards: 3, serial_paths: [ "spec/migrations/" ], serial_shard: nil)
      described_class.grade_steps(
        config: {
          "tags" => { "ci" => { "include" => [ "ci_only" ] } },
          "parallel_rspec" => {
            "enabled" => true, "rspec_modes" => [ "ci" ], "exec_args" => "bin/rspec-worker",
            "serial_paths" => serial_paths, "shards" => shards, "serial_shard" => serial_shard
          }.compact
        },
        default_failures: "strict"
      ).select { |step| step.name.start_with?("rspec-ci") }
    end

    def write_specs(dir, files)
      files.each do |path, bytes|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        File.write(File.join(dir, path), "#" * bytes)
      end
    end

    let(:spec_tree) do
      {
        "spec/models/a_spec.rb" => 900, "spec/models/b_spec.rb" => 700, "spec/services/c_spec.rb" => 650,
        "spec/services/d_spec.rb" => 300, "spec/jobs/e_spec.rb" => 280, "spec/jobs/f_spec.rb" => 120,
        "spec/requests/g_spec.rb" => 90, "spec/migrations/serial_spec.rb" => 5000, "spec/support/helper.rb" => 400
      }
    end

    def files_run_by(step)
      _out, err, status, parallel_args = run_generated_rspec_command(step.run, parallel_status: 0) { |dir| write_specs(dir, spec_tree) }
      expect(status).to be_success, err
      parallel_args.split.select { |arg| arg.end_with?("_spec.rb") }
    end

    it "expands the CI grader into named shards that each supersede the plain suite" do
      steps = sharded_steps

      expect(steps.map(&:name)).to eq(%w[rspec-ci-1-of-3 rspec-ci-2-of-3 rspec-ci-3-of-3])
      expect(steps.map { |step| step.metadata["supersedes"] }).to all(eq("rspec"))
      expect(steps.map { |step| step.metadata["shard"] }).to eq([ 1, 2, 3 ].map { |index| { "index" => index, "count" => 3 } })
      expect(steps.map(&:phases)).to all(eq(%w[ci]))
    end

    it "runs every non-serial spec file in exactly one shard" do
      slices = sharded_steps.map { |step| files_run_by(step) }

      expect(slices.flatten).to match_array(spec_tree.keys.select { |path| path.end_with?("_spec.rb") } - [ "spec/migrations/serial_spec.rb" ])
      expect(slices.flatten.uniq.size).to eq(slices.flatten.size)
      expect(slices).to all(be_present)
    end

    it "balances shards by file size" do
      sizes = sharded_steps.map { |step| files_run_by(step).sum { |path| spec_tree.fetch(path) } }

      expect(sizes.max - sizes.min).to be <= spec_tree.fetch("spec/models/b_spec.rb")
    end

    it "names one suite-wide runtime profile every shard reads" do
      steps = sharded_steps

      expect(steps.map { |step| step.metadata["shard_runtime_profile_destination"] }.uniq).to eq([ ".syrus/shard_runtime_rspec-ci.log" ])
      expect(steps.map { |step| step.metadata["shard_runtime_profile_key"] }.uniq).to eq([ "rspec-ci" ])
    end

    describe "with a materialized runtime profile" do
      # Runtimes deliberately disagree with file sizes: the smallest files are
      # the slowest, as request and system specs often are.
      let(:runtimes) do
        {
          "spec/models/a_spec.rb" => 2.0, "spec/models/b_spec.rb" => 2.0, "spec/services/c_spec.rb" => 3.0,
          "spec/services/d_spec.rb" => 4.0, "spec/jobs/e_spec.rb" => 40.0, "spec/jobs/f_spec.rb" => 45.0
        }
      end

      def files_run_with_profile(step, profile)
        _out, err, status, parallel_args = run_generated_rspec_command(step.run, parallel_status: 0) do |dir|
          write_specs(dir, spec_tree)
          path = File.join(dir, step.metadata.fetch("shard_runtime_profile_destination"))
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, profile.map { |file, seconds| "#{file}:#{seconds}" }.join("\n") + "\n")
        end
        expect(status).to be_success, err
        parallel_args.split.select { |arg| arg.end_with?("_spec.rb") }
      end

      it "balances shards by recorded runtime and still runs every file exactly once" do
        slices = sharded_steps.map { |step| files_run_with_profile(step, runtimes) }
        spec_files = spec_tree.keys.select { |path| path.end_with?("_spec.rb") } - [ "spec/migrations/serial_spec.rb" ]

        expect(slices.flatten).to match_array(spec_files)
        expect(slices.flatten.uniq.size).to eq(slices.flatten.size)
        # The two slow files land on different shards instead of together.
        expect(slices.map { |slice| (slice & %w[spec/jobs/e_spec.rb spec/jobs/f_spec.rb]).size }.max).to eq(1)
      end

      it "weights a file missing from the profile by size at the profiled rate" do
        partial = runtimes.except("spec/requests/g_spec.rb")
        slices = sharded_steps.map { |step| files_run_with_profile(step, partial) }

        expect(slices.flatten).to include("spec/requests/g_spec.rb")
        expect(slices.flatten.uniq.size).to eq(slices.flatten.size)
      end
    end

    it "runs the serial paths once, in the last shard" do
      first, *, last = sharded_steps

      expect(first.run).not_to match(%r{bundle exec rspec [^;]* spec/migrations/})
      expect(last.run).to match(%r{RUN_CI_ONLY_SPECS=true bundle exec rspec [^;]* spec/migrations/})
    end

    it "runs the serial paths in a grader of their own with serial_shard" do
      steps = sharded_steps(serial_shard: true)

      expect(steps.map(&:name)).to eq(%w[rspec-ci-1-of-3 rspec-ci-2-of-3 rspec-ci-3-of-3 rspec-ci-serial])
      expect(steps.map(&:display_name)).to eq([ "RSpec (CI) 1/3", "RSpec (CI) 2/3", "RSpec (CI) 3/3", "RSpec (CI) serial" ])
      steps.first(3).each do |shard|
        expect(shard.run).not_to match(%r{bundle exec rspec [^;]* spec/migrations/})
      end
      serial = steps.last
      expect(serial.run).to match(%r{RUN_CI_ONLY_SPECS=true bundle exec rspec [^;]* spec/migrations/})
      expect(serial.run).not_to include("parallel_rspec")
      expect(serial.metadata).to include("supersedes" => "rspec", "grader_mode" => "ci")
      expect(serial.phases).to eq(%w[ci])
    end

    it "passes an empty shard without running the whole default suite" do
      step = sharded_steps(shards: 12).last

      _out, _err, status, parallel_args = run_generated_rspec_command(step.run, parallel_status: 1) { |dir| write_specs(dir, spec_tree) }

      expect(status).to be_success
      expect(parallel_args).to be_empty
    end

    it "fails the shard when its file list cannot be computed rather than passing vacuously" do
      step = sharded_steps.first
      Dir.mktmpdir("rspec-shard-fail") do |dir|
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "ruby"), "#!/usr/bin/env bash\nexit 3\n")
        File.write(File.join(bin, "bundle"), "#!/usr/bin/env bash\nexit 0\n")
        File.write(File.join(bin, "parallel_rspec"), "#!/usr/bin/env bash\nexit 0\n")
        FileUtils.chmod("+x", Dir[File.join(bin, "*")])

        _out, _err, status = Open3.capture3({ "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }, "bash", "-c", step.run, chdir: dir)

        expect(status).not_to be_success
      end
    end

    it "keeps a single CI grader without shards" do
      expect(sharded_steps(shards: 1).map(&:name)).to eq(%w[rspec-ci])
    end

    it "rejects shards on a CI shape that cannot be split" do
      expect { sharded_steps(serial_paths: []) }.to raise_error(ArgumentError, /parallel_rspec.shards/)
    end
  end

  it "registers the rspec type name" do
    expect(described_class.type_name).to eq("rspec")
  end

  describe "resource requests" do
    it "asks for every core a parallel run can use and leaves serial modes unclaimed" do
      steps = described_class.grade_steps(
        config: { "parallel_rspec" => { "rspec_modes" => [ "full" ] } },
        default_failures: "strict"
      )

      full = steps.find { |step| step.metadata["grader_mode"] == "full" }
      focused = steps.find { |step| step.metadata["grader_mode"] == "focused" }

      expect(full.resources).to be_unbounded_cpu
      expect(full.resources.cpu_min).to eq(2)
      # A serial run cannot use a second core and must not claim one, or it
      # would starve a peer that can.
      expect(focused.resources).to be_nil
    end

    it "claims nothing at all when parallel_rspec is off" do
      steps = described_class.grade_steps(config: {}, default_failures: "strict")

      expect(steps.map(&:resources)).to all(be_nil)
    end

    it "lets an explicit resources declaration win over the generated default" do
      steps = described_class.grade_steps(
        config: {
          "parallel_rspec" => { "rspec_modes" => [ "full" ] },
          "resources" => { "cpu" => 4, "memory" => "6GB" }
        },
        default_failures: "strict"
      )

      request = steps.first.resources
      expect(request).not_to be_unbounded_cpu
      expect(request.cpu).to eq(4)
      expect(request.memory_bytes).to eq(6 * 1024**3)
    end

    it "reports a malformed declaration as a config error" do
      expect {
        described_class.grade_steps(config: { "resources" => { "cpu" => 0 } }, default_failures: "strict")
      }.to raise_error(ArgumentError, /positive integer/)
    end
  end

  it "generates a focused command whose embedded ruby selector survives .squish intact" do
    Dir.mktmpdir do |dir|
      run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
      run_git.call("init", "-q", "-b", "main")
      run_git.call("config", "user.email", "test@example.com")
      run_git.call("config", "user.name", "Test")
      run_git.call("config", "commit.gpgsign", "false")
      FileUtils.mkdir_p(File.join(dir, "spec/models/concerns"))
      File.write(File.join(dir, "spec/models/concerns/widget_spec.rb"), "RSpec.describe(Widget) {}\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "base")
      run_git.call("checkout", "-q", "-b", "feature")
      FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
      File.write(File.join(dir, "app/models/concerns/widget.rb"), "class Widget; end\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "feature")

      command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
      selector = command[command.index("ruby -e ")...command.index(" > .syrus/rspec-focused-files")]

      stdout, stderr, status = Open3.capture3("bash", "-c", selector, chdir: dir)

      expect(status).to be_success, "expected the focused-file selector to run without a shell/ruby syntax error, got:\n#{stderr}"
      expect(stdout).to include("spec/models/concerns/widget_spec.rb")
    end
  end

  it "maps gem-style lib changes to specs under spec without requiring a main or master ref" do
    Dir.mktmpdir do |dir|
      run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
      run_git.call("init", "-q", "-b", "develop")
      run_git.call("config", "user.email", "test@example.com")
      run_git.call("config", "user.name", "Test")
      run_git.call("config", "commit.gpgsign", "false")
      FileUtils.mkdir_p(File.join(dir, "spec/foo"))
      File.write(File.join(dir, "spec/foo/bar_spec.rb"), "RSpec.describe(Foo::Bar) {}\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "base")
      run_git.call("checkout", "-q", "-b", "feature")
      FileUtils.mkdir_p(File.join(dir, "lib/foo"))
      File.write(File.join(dir, "lib/foo/bar.rb"), "module Foo; class Bar; end; end\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "feature")

      command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
      stdout, stderr, status = Open3.capture3("ruby", "-e", focused_selector_from(command), chdir: dir)

      expect(status).to be_success, "expected the focused-file selector to run, got:\n#{stderr}"
      expect(stdout.lines.map(&:strip)).to include("spec/foo/bar_spec.rb")
    end
  end

  it "falls back to the full RSpec suite when focused selection has no resolvable base" do
    command = described_class.grade_steps(config: {}, default_failures: "strict").second.run

    stdout, _stderr, status = run_generated_rspec_command(command, parallel_status: 0, serial_status: 7) do |dir|
      FileUtils.mkdir_p(File.join(dir, ".syrus"))
    end

    expect(stdout).to include("falling back to full RSpec suite")
    expect(status.exitstatus).to eq(7)
  end

  it "skips a transitively selected focused grader when no changed Ruby files match its scope" do
    command = described_class.grade_steps(
      config: { "when_files_changed" => [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ] },
      default_failures: "strict"
    ).second.run

    stdout, _stderr, status = run_generated_rspec_command(command, parallel_status: 7, serial_status: 7) do |dir|
      run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
      run_git.call("init", "-q", "-b", "main")
      run_git.call("config", "user.email", "test@example.com")
      run_git.call("config", "user.name", "Test")
      run_git.call("config", "commit.gpgsign", "false")
      FileUtils.mkdir_p(File.join(dir, ".syrus"))
      File.write(File.join(dir, "README.md"), "base\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "base")
      run_git.call("checkout", "-q", "-b", "feature")
      FileUtils.mkdir_p(File.join(dir, "plugins/example/lib"))
      File.write(File.join(dir, "plugins/example/lib/example.rb"), "module Example; end\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "plugin change")
    end

    expect(stdout).to include("No changed Ruby files matched this RSpec grader's scope; skipping")
    expect(status).to be_success
  end

  # A repository commit where the changed file has no same-named spec.
  def commit_uncovered_change(dir, referencing_spec: nil)
    run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
    run_git.call("init", "-q", "-b", "main")
    run_git.call("config", "user.email", "test@example.com")
    run_git.call("config", "user.name", "Test")
    run_git.call("config", "commit.gpgsign", "false")
    FileUtils.mkdir_p(File.join(dir, ".syrus"))
    FileUtils.mkdir_p(File.join(dir, "spec/services"))
    File.write(File.join(dir, "spec/services/unrelated_spec.rb"), "RSpec.describe(Unrelated) {}\n")
    File.write(File.join(dir, "spec/services/caller_spec.rb"), referencing_spec) if referencing_spec
    run_git.call("add", "-A")
    run_git.call("commit", "-q", "-m", "base")
    run_git.call("checkout", "-q", "-b", "feature")
    FileUtils.mkdir_p(File.join(dir, "app/services/billing"))
    File.write(File.join(dir, "app/services/billing/invoice_mailer.rb"), "module Billing; class InvoiceMailer; end; end\n")
    run_git.call("add", "-A")
    run_git.call("commit", "-q", "-m", "change without a same-named spec")
  end

  it "selects specs that reference a changed constant when no same-named spec exists" do
    command = described_class.grade_steps(config: {}, default_failures: "strict").second.run

    Dir.mktmpdir do |dir|
      commit_uncovered_change(dir, referencing_spec: "RSpec.describe(Billing::InvoiceMailer) {}\n")
      stdout, stderr, status = Open3.capture3({ "SYRUS_BASE_REF" => "main" }, "ruby", "-e", focused_selector_from(command),
        chdir: dir)

      expect(status).to be_success, stderr
      expect(stdout.lines.map(&:strip)).to eq([ "spec/services/caller_spec.rb" ])
    end
  end

  describe "focused_always_include" do
    def focused_args_for(referencing_spec: nil)
      command = described_class.grade_steps(
        config: { "focused_always_include" => [ "spec/architecture/", "spec/missing/" ] },
        default_failures: "strict"
      ).second.run
      args_file = Tempfile.new("focused-rspec-args")
      stdout, stderr, status = run_generated_rspec_command(command, parallel_status: 0, serial_status: 0,
        extra_env: { "SYRUS_BASE_REF" => "main" }) do |dir|
        commit_uncovered_change(dir, referencing_spec: referencing_spec)
        FileUtils.mkdir_p(File.join(dir, "spec/architecture"))
        File.write(File.join(dir, "spec/architecture/layers_spec.rb"), "RSpec.describe(:layers) {}\n")
        File.write(File.join(dir, "bin/rspec"), "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" > #{args_file.path}\nexit 0\n")
      end
      expect(status).to be_success, stderr
      [ stdout, File.read(args_file.path) ]
    ensure
      args_file&.close!
    end

    # Repository-wide invariant specs fail on changes no changed-file
    # selection maps to them, so they surfaced first on merge trains.
    it "adds the configured paths that exist to the selected focused specs" do
      _stdout, args = focused_args_for(referencing_spec: "RSpec.describe(Billing::InvoiceMailer) {}\n")

      expect(args).to include("spec/services/caller_spec.rb", "spec/architecture/")
      expect(args).not_to include("spec/missing/")
    end

    it "runs only the configured paths when no spec covers the change" do
      stdout, args = focused_args_for

      expect(stdout).to include("running only the always-included specs")
      expect(args).to include("spec/architecture/")
      expect(args).not_to include("unrelated_spec.rb")
    end
  end

  # Regression: a change with no covering spec fell back to the full suite
  # under the 10-minute focused budget, which it can never finish -- the
  # grader timed out on every attempt and failed the workflow.
  it "skips the focused run instead of running the full suite when no spec covers the change" do
    command = described_class.grade_steps(config: {}, default_failures: "strict").second.run

    stdout, _stderr, status = run_generated_rspec_command(command, parallel_status: 7, serial_status: 7,
      extra_env: { "SYRUS_BASE_REF" => "main" }) { |dir| commit_uncovered_change(dir) }

    expect(stdout).to include("No RSpec files cover the changed Ruby files; skipping the focused run")
    expect(stdout).not_to include("falling back to full RSpec suite")
    expect(status).to be_success
  end

  it "expands to typed focused review, full landing, and ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[rspec rspec-focused rspec-ci])
    expect(steps.first.run).to include("bundle exec rspec")
    expect(steps.first.run).to include("RAILS_ENV=test bin/rails db:test:prepare")
    expect(steps.first.run).to include("--tag \\~ci_only")
    expect(steps.first.run).to include("spec")
    expect(steps.first.run).to include(".syrus/rspec-json/rspec.json")
    expect(steps.first.phases).to eq(%w[landing])
    expect(steps.first.failures).to eq("allow_inherited")
    expect(steps.first.base_retry).to eq(SyrusYml::BaseRetry.new(strategy: "plugin", command: nil))
    expect(steps.first.junit_output).to eq(".syrus/grade-output/rspec-junit.xml")
    expect(steps.first.metadata).to include(
      "grader_type" => "rspec",
      "grader_framework" => "rspec",
      "grader_mode" => "full"
    )

    expect(steps.second.run).to include(".syrus/rspec-focused-files")
    expect(steps.second.phases).to eq(%w[review])
    expect(steps.second.when_files_changed).to include("**/*.rb", "*.gemspec", "Gemfile")
    expect(steps.second.metadata["grader_mode"]).to eq("focused")

    expect(steps.third.run).to include("RUN_CI_ONLY_SPECS=true")
    expect(steps.third.run).to include("spec")
    expect(steps.third.run).not_to include("--tag ~ci_only")
    expect(steps.third.phases).to eq(%w[ci])
    expect(steps.third.metadata["grader_mode"]).to eq("ci")
  end

  it "keeps the default expansion when explicit paths are configured without fixed full-path mode" do
    steps = described_class.grade_steps(
      config: {
        "name" => "simulation-specs",
        "paths" => [ "spec/services/simulation_spec.rb" ],
        "phases" => %w[review landing ci]
      },
      default_failures: "strict"
    )

    expect(steps.map(&:name)).to eq(%w[simulation-specs simulation-specs-focused simulation-specs-ci])
    expect(steps.map(&:phases)).to eq([ %w[landing], %w[review], %w[ci] ])
    expect(steps.first.run).to include("spec/services/simulation_spec.rb")
    expect(steps.second.run).to include(".syrus/rspec-focused-files")
    expect(steps.third.run).to include("RUN_CI_ONLY_SPECS=true")
  end

  it "maps unland to the focused command without selecting the full command" do
    steps = described_class.grade_steps(config: { "phases" => %w[unland] }, default_failures: "strict")

    expect(steps.map { |entry| [ entry.name, entry.phases, entry.metadata["grader_mode"] ] }).to eq([
      [ "rspec", [], "full" ],
      [ "rspec-focused", %w[unland], "focused" ],
      [ "rspec-ci", [], "ci" ]
    ])
  end

  it "supports a fixed full-path grader that runs configured paths in every selected phase" do
    steps = described_class.grade_steps(
      config: {
        "name" => "work-engine-simulations",
        "fixed_full_path" => true,
        "paths" => [ "spec/services/work_engine/simulation/scenario_runner_spec.rb" ],
        "phases" => %w[review landing ci],
        "when_files_changed" => [ "app/services/work_engine/**/*.rb", "spec/services/work_engine/**/*.rb" ],
        "timeout_minutes" => 12,
        "required" => false,
        "failures" => "allow_inherited",
        "display_name" => "Work engine simulations"
      },
      default_failures: "strict"
    )

    expect(steps.size).to eq(1)
    step = steps.sole
    expect(step.name).to eq("work-engine-simulations")
    expect(step.display_name).to eq("Work engine simulations")
    expect(step.phases).to eq(%w[review landing ci])
    expect(step.run).to include("bundle exec rspec")
    expect(step.run).to include("spec/services/work_engine/simulation/scenario_runner_spec.rb")
    expect(step.run).not_to include(".syrus/rspec-focused-files")
    expect(step.run).not_to include("RUN_CI_ONLY_SPECS=true")
    expect(step.run).to include(".syrus/rspec-json/work-engine-simulations.json")
    expect(step.junit_output).to eq(".syrus/grade-output/work-engine-simulations-junit.xml")
    expect(step.when_files_changed).to eq([ "app/services/work_engine/**/*.rb", "spec/services/work_engine/**/*.rb" ])
    expect(step.timeout_minutes).to eq(12)
    expect(step.required).to be(false)
    expect(step.failures).to eq("allow_inherited")
    expect(step.base_retry).to eq(SyrusYml::BaseRetry.new(strategy: "plugin", command: nil))
    expect(step.metadata).to include(
      "grader_type" => "rspec",
      "grader_framework" => "rspec",
      "grader_mode" => "full"
    )
    expect(step.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/grade-output/work-engine-simulations-junit.xml", "format" => "junit" }
    ])
  end

  it "requires explicit paths for fixed full-path mode" do
    expect {
      described_class.grade_steps(config: { "fixed_full_path" => true }, default_failures: "strict")
    }.to raise_error(ArgumentError, "fixed_full_path requires paths or spec_paths")
  end

  it "accepts spec_paths for fixed full-path mode" do
    step = described_class.grade_steps(
      config: { "fixed_full_path" => true, "spec_paths" => [ "spec/system/widget_spec.rb" ] },
      default_failures: "strict"
    ).sole

    expect(step.name).to eq("rspec")
    expect(step.run).to include("spec/system/widget_spec.rb")
  end

  it "synthesizes mode-aware operator-facing display names by default" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:display_name)).to eq([ "RSpec", "RSpec (focused)", "RSpec (CI)" ])
  end

  it "lets an explicit display_name override the generated default for every mode" do
    steps = described_class.grade_steps(config: { "display_name" => "Ruby suite" }, default_failures: "strict")

    expect(steps.map(&:display_name)).to eq([ "Ruby suite" ] * 3)
  end

  it "lets a per-mode display_name override win over the blanket display_name" do
    steps = described_class.grade_steps(
      config: { "display_name" => "Ruby suite", "focused_display_name" => "Ruby suite (quick)" },
      default_failures: "strict"
    )

    expect(steps.map(&:display_name)).to eq([ "Ruby suite", "Ruby suite (quick)", "Ruby suite" ])
  end

  it "uses configured project scope for every generated grader" do
    steps = described_class.grade_steps(
      config: { "when_files_changed" => [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ] },
      default_failures: "strict"
    )

    expect(steps.map(&:when_files_changed)).to eq([
      [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ],
      [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ],
      [ "app/**/*.rb", "lib/**/*.rb", "spec/**/*.rb" ]
    ])
  end

  it "uses root-relative command paths and unique artifacts for nested projects" do
    steps = described_class.grade_steps(
      config: { "_syrus_project_path" => "plugins/example" },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("bundle exec rspec")
    expect(steps.first.run).to include("plugins/example/spec")
    expect(steps.first.junit_output).to eq(".syrus/grade-output/plugins-example-rspec-junit.xml")
    expect(steps.first.run).to include(".syrus/rspec-json/plugins-example-rspec.json")
    expect(steps.second.run).to include("plugins/example")
    expect(steps.second.junit_output).to eq(".syrus/grade-output/plugins-example-rspec-focused-junit.xml")
    expect(steps.first.when_files_changed).to include("**/*.rb", "Gemfile")
  end

  it "passes dependency labels through typed grader expansion" do
    steps = described_class.grade_steps(
      config: { "deps" => [ "//plugins/ruby:grade/rspec" ] },
      default_failures: "strict"
    )

    expect(steps.map(&:deps)).to eq([
      [ "//plugins/ruby:grade/rspec" ],
      [ "//plugins/ruby:grade/rspec" ],
      [ "//plugins/ruby:grade/rspec" ]
    ])
  end

  it "allows a custom name prefix and inherited-failure policy" do
    steps = described_class.grade_steps(
      config: { "name" => "ruby-specs", "failures" => "allow_inherited", "required" => false, "timeout_minutes" => 30 },
      default_failures: "strict"
    )

    expect(steps.map(&:name)).to eq(%w[ruby-specs ruby-specs-focused ruby-specs-ci])
    expect(steps.map(&:failures)).to eq(%w[allow_inherited allow_inherited allow_inherited])
    expect(steps.map(&:required)).to eq([ false, false, false ])
    expect(steps.map(&:timeout_minutes)).to eq([ 30, 30, 30 ])
  end

  it "can restrict generated graders by phase" do
    steps = described_class.grade_steps(
      config: { "phases" => [ "review", "landing" ] },
      default_failures: "strict"
    )

    expect(steps.map { |step| [ step.name, step.phases ] }).to eq([
      [ "rspec", %w[landing] ],
      [ "rspec-focused", %w[review] ],
      [ "rspec-ci", [] ]
    ])
  end

  it "supports tag filters per generated RSpec mode" do
    steps = described_class.grade_steps(
      config: {
        "tags" => {
          "exclude" => [ "slow" ],
          "fast" => { "exclude" => [ "external" ] },
          "focused" => { "include" => [ "models" ] },
          "ci" => { "include" => [ "ci_only" ] }
        }
      },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("--tag \\~external")
    expect(steps.first.run).to include("--tag \\~slow")
    expect(steps.second.run).to include("--tag models")
    expect(steps.second.run).to include("--tag ~slow")
    expect(steps.third.run).to include("--tag ci_only")
    expect(steps.third.run).to include("--tag \\~slow")
  end

  it "keeps the focused selector as valid Ruby after shell escaping" do
    command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
    script = focused_selector_from(command)

    expect { RubyVM::InstructionSequence.compile(script) }.not_to raise_error
    expect(script).to include("git symbolic-ref -q --short refs/remotes/origin/HEAD")
  end

  # The gate exists so a repair that did not work is rejected in seconds
  # instead of after a full suite. It must never decide success on its own:
  # a narrowed pass proves nothing, so the full command still runs behind it.
  describe "previous-failure fail-fast gate" do
    def gate_command
      described_class.grade_steps(
        config: {
          "parallel_rspec" => {
            "enabled" => true,
            "rspec_modes" => [ "full" ],
            "processes" => "2",
            "exec_args" => "bin/rspec-worker"
          }
        },
        default_failures: "strict"
      ).first.run
    end

    def ci_gate_command
      described_class.grade_steps(
        config: {
          "tags" => { "ci" => { "include" => [ "ci_only" ] } },
          "parallel_rspec" => {
            "enabled" => true,
            "rspec_modes" => [ "ci" ],
            "processes" => "2",
            "exec_args" => "bin/rspec-worker"
          }
        },
        default_failures: "strict"
      ).third.run
    end

    def run_gate(command, previous_specs:, gate_status: 0, gate_examples: 1, parallel_status: 0)
      Dir.mktmpdir("rspec-grader-gate") do |dir|
        bin_dir = File.join(dir, "bin")
        FileUtils.mkdir_p(bin_dir)
        File.write(File.join(bin_dir, "bundle"), <<~BASH)
          #!/usr/bin/env bash
          case "$1" in
            check|install) exit 0 ;;
            exec)
              shift
              if [ "$1" = "rspec" ]; then
                echo "GATE_RAN RUN_CI_ONLY_SPECS=${RUN_CI_ONLY_SPECS:-} args=$*" >> "$TRACE"
                json_path=""
                while [ "$#" -gt 0 ]; do
                  if [ "$1" = "--out" ]; then json_path="$2"; shift 2; else shift; fi
                done
                if [ -n "$json_path" ]; then printf '{"summary":{"example_count":%s}}' "${FAKE_GATE_EXAMPLES:-1}" > "$json_path"; fi
                exit "${FAKE_GATE_STATUS:-0}"
              fi
              "$@"; exit $? ;;
            *) exit 64 ;;
          esac
        BASH
        File.write(File.join(bin_dir, "parallel_rspec"), <<~BASH)
          #!/usr/bin/env bash
          echo "FULL_RAN" >> "$TRACE"
          exit "${FAKE_PARALLEL_RSPEC_STATUS:-0}"
        BASH
        File.write(File.join(bin_dir, "ruby"), <<~BASH)
          #!/usr/bin/env bash
          if [[ "$*" == *previous-failures-gate.json* ]]; then
            [ "${FAKE_GATE_EXAMPLES:-1}" -gt 0 ]
            exit $?
          fi
          exit 0
        BASH
        FileUtils.chmod("+x", Dir[File.join(bin_dir, "*")])
        trace = File.join(dir, "trace")

        env = {
          "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}",
          "TRACE" => trace,
          "SYRUS_PREVIOUS_FAILED_SPECS" => previous_specs,
          "FAKE_GATE_STATUS" => gate_status.to_s,
          "FAKE_GATE_EXAMPLES" => gate_examples.to_s,
          "FAKE_PARALLEL_RSPEC_STATUS" => parallel_status.to_s,
          "BUNDLE_GEMFILE" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
          "RUBYLIB" => nil, "RUBYOPT" => nil
        }
        _o, _e, status = Open3.capture3(env, "bash", "-c", command, chdir: dir)
        [ status.exitstatus, (File.read(trace) rescue "") ]
      end
    end

    it "skips the full suite when the previously failing files still fail" do
      exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_status: 1)

      expect(exitstatus).to eq(1)
      expect(trace).to include("GATE_RAN")
      expect(trace).not_to include("FULL_RAN")
    end

    # Regression: the gate wrote only JSON, so a round that stopped at the
    # gate left no JUnit for Test Insights. Every repair round after the first
    # then had no failed-test evidence, and a merge train could never show its
    # failures were inherited from main -- it ran landing_fix five times.
    it "records the gate's failures as JUnit where the full suite would" do
      _exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_status: 1)
      gate_trace = trace.lines.find { |line| line.include?("previous-failures-gate.json") }

      expect(gate_trace).to include("--require rspec_junit_formatter", "--format RspecJunitFormatter", "--out .syrus/grade-output/rspec-junit.xml")
    end

    it "still runs the full suite when the gate passes" do
      exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_status: 0)

      expect(exitstatus).to eq(0)
      expect(trace).to include("GATE_RAN")
      expect(trace).to include("FULL_RAN")
    end

    it "fails instead of passing vacuously when supplied files run no examples" do
      exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_examples: 0)

      expect(exitstatus).to eq(1)
      expect(trace).to include("GATE_RAN")
      expect(trace).not_to include("FULL_RAN")
    end

    it "uses the full-suite tag policy for the full-mode gate" do
      _exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb")

      expect(trace).to include("RUN_CI_ONLY_SPECS=false")
      expect(trace).to include("--tag ~ci_only")
    end

    it "runs both normal and CI-only examples in the CI-mode gate" do
      _exitstatus, trace = run_gate(ci_gate_command, previous_specs: "spec/a_spec.rb")
      gate_trace = trace.lines.find { |line| line.include?("previous-failures-gate.json") }

      expect(gate_trace).to include("RUN_CI_ONLY_SPECS=true")
      expect(gate_trace).not_to include("--tag ci_only")
      expect(gate_trace).not_to include("--tag ~ci_only")
    end

    it "does not let a passing gate hide a failing suite" do
      exitstatus, _trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_status: 0, parallel_status: 1)

      expect(exitstatus).to eq(1)
    end

    it "is skipped entirely with no recorded failures" do
      exitstatus, trace = run_gate(gate_command, previous_specs: "")

      expect(exitstatus).to eq(0)
      expect(trace).not_to include("GATE_RAN")
      expect(trace).to include("FULL_RAN")
    end
  end

  # Regression: the shard-JUnit merge ran after `set -e`, so when it failed
  # the shell aborted before the status check and the grader reported the
  # merge's error instead of the test outcome -- with no evidence attached. A
  # production repair loop lost its failing-test list that way and fell back
  # to naming the grader's own shell command, leaving the next iteration with
  # nothing to act on. A failed merge may cost evidence, never the verdict.
  describe "shard JUnit merge failures" do
    def run_with_failing_merge(command, parallel_status:)
      Dir.mktmpdir("rspec-grader-merge") do |dir|
        bin_dir = File.join(dir, "bin")
        FileUtils.mkdir_p(bin_dir)
        File.write(File.join(bin_dir, "bundle"), <<~BASH)
          #!/usr/bin/env bash
          case "$1" in
            check|install) exit 0 ;;
            exec) shift; "$@"; exit $? ;;
            *) exit 64 ;;
          esac
        BASH
        File.write(File.join(bin_dir, "parallel_rspec"), <<~BASH)
          #!/usr/bin/env bash
          exit "${FAKE_PARALLEL_RSPEC_STATUS:-0}"
        BASH
        # Only the merge step shells out to `ruby`, so failing it here fails
        # exactly the merge and nothing else in the generated command.
        File.write(File.join(bin_dir, "ruby"), <<~BASH)
          #!/usr/bin/env bash
          echo "merge blew up" >&2
          exit 1
        BASH
        FileUtils.chmod("+x", Dir[File.join(bin_dir, "*")])

        env = {
          "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}",
          "FAKE_PARALLEL_RSPEC_STATUS" => parallel_status.to_s,
          "BUNDLE_GEMFILE" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil,
          "RUBYLIB" => nil, "RUBYOPT" => nil
        }
        Open3.capture3(env, "bash", "-c", command, chdir: dir)
      end
    end

    let(:parallel_command) do
      described_class.grade_steps(
        config: {
          "parallel_rspec" => {
            "enabled" => true,
            "rspec_modes" => [ "full" ],
            "processes" => "2",
            "exec_args" => "bin/rspec-worker"
          }
        },
        default_failures: "strict"
      ).first.run
    end

    it "still reports success when the merge fails but the tests passed" do
      _out, _err, status = run_with_failing_merge(parallel_command, parallel_status: 0)

      expect(status.exitstatus).to eq(0)
    end

    it "still reports the test failure rather than the merge error" do
      _out, _err, status = run_with_failing_merge(parallel_command, parallel_status: 1)

      expect(status.exitstatus).to eq(1)
    end
  end

  it "uses configured parallel_rspec for fast and focused modes" do
    steps = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full", "focused" ],
          "processes" => "4",
          "group_by" => "runtime",
          "allowed_missing" => "100",
          "unknown_runtime" => "0.1",
          "exec_args" => "bin/rspec-worker",
          "prepare_command" => "bundle exec rake parallel:prepare"
        }
      },
      default_failures: "strict"
    )

    expect(steps.first.run).to include('RSPEC_PARALLEL_PROCESSES="${SYRUS_PROCESS_PARALLELISM:-}"')
    expect(steps.first.run).to include('RSPEC_PARALLEL_PROCESSES=4')
    expect(steps.first.run).to include('bundle exec parallel_rspec $parallel_runtime_args -n "$RSPEC_PARALLEL_PROCESSES" --quiet')
    expect(steps.first.run).to include("--group-by\\ runtime")
    expect(steps.first.run).to include("--allowed-missing\\ 100")
    expect(steps.first.run).to include("--unknown-runtime\\ 0.1")
    expect(steps.first.run).to include("--runtime-log\\ .syrus/parallel_runtime_rspec.log")
    expect(steps.first.run).to include("grouping shards by file size")
    expect(steps.first.run).to include("--exec-args bin/rspec-worker spec")
    expect(steps.first.run).to include("bundle exec rake parallel:prepare")
    expect(steps.first.run).to include('PARALLEL_TEST_PROCESSORS="$RSPEC_PARALLEL_PROCESSES" bundle exec rake parallel:prepare')
    expect(steps.first.run.index('RSPEC_PARALLEL_PROCESSES="${SYRUS_PROCESS_PARALLELISM:-}"')).to be <
      steps.first.run.index("bundle exec rake parallel:prepare")
    expect(steps.first.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~ci_only")
    expect(steps.first.run).to include("RSPEC_OUTPUT_PREFIX=rspec")
    expect(steps.first.metadata["runtime_profile_destination"]).to eq(".syrus/parallel_runtime_rspec.log")
    expect(steps.first.run).to include("parallel-rspec-junit")
    expect(steps.second.run).to include('bundle exec parallel_rspec $parallel_runtime_args -n "$RSPEC_PARALLEL_PROCESSES" --quiet')
    expect(steps.second.run).to include("--exec-args bin/rspec-worker $(cat .syrus/rspec-focused-files)")
    expect(steps.third.run).to include("bundle exec rspec")
    expect(steps.third.run).not_to include("parallel_rspec")
  end

  it "passes the resolved capped worker count to the parallel prepare command" do
    step = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full" ],
          "processes" => "4",
          "prepare_command" => "sh -c 'echo PREPARE_COUNT=$PARALLEL_TEST_PROCESSORS'"
        }
      },
      default_failures: "strict"
    ).first

    stdout, stderr, status = run_generated_rspec_command(
      step.run,
      parallel_status: 0,
      extra_env: { "SYRUS_PROCESS_PARALLELISM" => "7" }
    )

    expect(status).to be_success, stderr
    expect(stdout).to include("PREPARE_COUNT=4")
  end

  # parallel_tests' own default balances shards by file count, which on this
  # suite produced a 2.5x spread between the fastest and slowest shard -- and
  # the slowest one sets the grader's wall clock. File size needs no recorded
  # state and is a much better runtime proxy.
  it "groups shards by file size when no runtime profile was materialized" do
    step = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full" ],
          "group_by" => "runtime",
          "exec_args" => "bin/rspec-worker"
        }
      },
      default_failures: "strict"
    ).first

    stdout, stderr, status, parallel_args = run_generated_rspec_command(step.run, parallel_status: 0)

    expect(status).to be_success, stderr
    expect(stdout).to include("grouping shards by file size")
    expect(parallel_args).to include("--group-by filesize")
    expect(parallel_args).not_to include("--group-by runtime")
  end

  # Steps::Grader#resource_grant_env sets SYRUS_PROCESS_PARALLELISM, yet every
  # production rspec run reports `source: host-cpu-fallback` with an -n equal
  # to the raw host CPU count -- 10 to 20 depending on the node, which is the
  # difference between a 10-minute and a 32-minute grader. The echo
  # distinguishes "never arrived" from "arrived empty"; nothing else in the
  # chain can tell those apart after the run.
  it "reports whether SYRUS_PROCESS_PARALLELISM arrived at the command" do
    step = described_class.grade_steps(
      config: { "parallel_rspec" => { "enabled" => true, "rspec_modes" => [ "full" ], "exec_args" => "bin/rspec-worker" } },
      default_failures: "strict"
    ).first

    expect(step.run).to include('echo "[rspec] SYRUS_PROCESS_PARALLELISM=[${SYRUS_PROCESS_PARALLELISM-<unset>}]"')
  end

  it "uses runtime grouping when the runtime profile was materialized" do
    step = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full" ],
          "group_by" => "runtime",
          "exec_args" => "bin/rspec-worker"
        }
      },
      default_failures: "strict"
    ).first

    _stdout, stderr, status, parallel_args = run_generated_rspec_command(step.run, parallel_status: 0) do |dir|
      FileUtils.mkdir_p(File.join(dir, ".syrus"))
      File.write(File.join(dir, ".syrus/parallel_runtime_rspec.log"), "spec/models/widget_spec.rb:1.23\n")
    end

    expect(status).to be_success, stderr
    expect(parallel_args).to include("--group-by runtime")
    expect(parallel_args).to include("--runtime-log .syrus/parallel_runtime_rspec.log")
  end

  it "splits CI into a parallel fast pass plus configured serial tag pass" do
    step = described_class.grade_steps(
      config: {
        "tags" => { "ci" => { "include" => [ "ci_only" ] } },
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "ci" ],
          "exec_args" => "bin/rspec-worker"
        }
      },
      default_failures: "strict"
    ).third

    expect(step.run).to include("RUN_CI_ONLY_SPECS=false")
    expect(step.run).to include('bundle exec parallel_rspec -n "$RSPEC_PARALLEL_PROCESSES" --quiet')
    expect(step.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~ci_only")
    expect(step.run).to include("RUN_CI_ONLY_SPECS=true bundle exec rspec")
    expect(step.run).to include("--tag ci_only")
    expect(step.run).to include("serial_status")

    _stdout, stderr, status = run_generated_rspec_command(step.run, parallel_status: 0, serial_status: 7)

    expect(status.exitstatus).to eq(7), "expected the generated CI command to preserve the serial pass status, got:\n#{stderr}"
  end

  it "supports direct parallel_rspec command generation without a worker wrapper" do
    step = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full" ],
          "processes" => "2"
        }
      },
      default_failures: "strict"
    ).first

    expect(step.run).to include('RSPEC_PARALLEL_PROCESSES="${SYRUS_PROCESS_PARALLELISM:-}"')
    expect(step.run).to include('RSPEC_PARALLEL_PROCESSES=2')
    expect(step.run).to include('bundle exec parallel_rspec -n "$RSPEC_PARALLEL_PROCESSES" --quiet')
    expect(step.run).to include("--test-options")
    expect(step.run).to include(".syrus/rspec-json/rspec-")
    expect(step.run).to include(".syrus/grade-output/parallel-rspec-junit/rspec-")
    expect(step.run.scan(/\sspec(?:;|\s)/).length).to eq(1)
  end

  # A production run logged a grant of 5 cores and then produced ~21 shards,
  # and nothing in the output said which number reached `-n` or where it came
  # from -- so "the grant never arrived" and "the grant arrived and was
  # overridden" were indistinguishable afterwards. Oversubscribing a CPU-capped
  # pod is the most expensive mistake this command can make, so the resolved
  # value and its provenance are reported.
  describe "parallelism reporting" do
    it "echoes the resolved process count and where it came from" do
      step = described_class.grade_steps(
        config: { "parallel_rspec" => { "rspec_modes" => [ "full" ] } },
        default_failures: "strict"
      ).first

      expect(step.run).to include('echo "[rspec] parallelism: -n $RSPEC_PARALLEL_PROCESSES (source: $RSPEC_PARALLEL_SOURCE;')
      expect(step.run).to include('RSPEC_PARALLEL_SOURCE="SYRUS_PROCESS_PARALLELISM"')
      expect(step.run).to include("RSPEC_PARALLEL_SOURCE=host-cpu-fallback")
    end

    it "names the configured cap as the source when one clamps the grant" do
      step = described_class.grade_steps(
        config: { "parallel_rspec" => { "rspec_modes" => [ "full" ], "processes" => "2" } },
        default_failures: "strict"
      ).first

      expect(step.run).to include("RSPEC_PARALLEL_SOURCE=parallel_rspec.processes-cap")
    end
  end

  it "executes parallel status checks when no serial pass is configured" do
    step = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full" ],
          "processes" => "2"
        }
      },
      default_failures: "strict"
    ).first

    _stdout, stderr, status = run_generated_rspec_command(step.run, parallel_status: 6)

    expect(status.exitstatus).to eq(6), "expected the generated parallel command to preserve parallel_rspec's status, got:\n#{stderr}"
  end

  it "keeps the parallel JUnit merger valid after command whitespace normalization" do
    step = described_class.grade_steps(
      config: { "parallel_rspec" => { "enabled" => true, "rspec_modes" => [ "full" ] } },
      default_failures: "strict"
    ).first
    encoded_script = step.run.match(/strict_decode64\(ARGV\.shift\)\)' (?<script>[A-Za-z0-9+\/=]+)/)[:script]
    script = Base64.strict_decode64(encoded_script)

    expect { RubyVM::InstructionSequence.compile(script) }.not_to raise_error
    expect(script).to include("rescue StandardError\n    next")

    Dir.mktmpdir("rspec-junit-merge") do |dir|
      shard_dir = File.join(dir, "shards")
      output = File.join(dir, "merged.xml")
      FileUtils.mkdir_p(shard_dir)
      File.write(File.join(shard_dir, "one.xml"), '<testsuite tests="2" failures="1" errors="0" skipped="0" time="1.25"/>')
      File.write(File.join(shard_dir, "broken.xml"), "not xml")
      command = step.run.match(/(?<command>ruby -rbase64 -rrexml\/document .*? #{Regexp.escape('.syrus/grade-output/rspec-junit.xml')})/)[:command]
      command = command.sub(".syrus/grade-output/parallel-rspec-junit", Shellwords.escape(shard_dir))
        .sub(".syrus/grade-output/rspec-junit.xml", Shellwords.escape(output))

      expect(system(command)).to be(true)
      merged = REXML::Document.new(File.read(output))
      expect(merged.root.attributes["tests"]).to eq("2")
      expect(merged.root.attributes["failures"]).to eq("1")
      expect(merged.root.elements.to_a("testsuite").size).to eq(1)
    end
  end

  it "supports per-mode timeout overrides" do
    steps = described_class.grade_steps(
      config: { "timeout_minutes" => 60, "timeouts" => { "focused" => 10 } },
      default_failures: "strict"
    )

    expect(steps.map { |step| [ step.name, step.timeout_minutes ] }).to eq([
      [ "rspec", 60 ],
      [ "rspec-focused", 10 ],
      [ "rspec-ci", 60 ]
    ])
  end

  it "allows timeouts up to the repository grader ceiling" do
    steps = described_class.grade_steps(
      config: { "timeout_minutes" => 120 },
      default_failures: "strict"
    )

    expect(steps.map(&:timeout_minutes)).to all(eq(120))
  end

  it "can disable the auto Rails test database prepare hook" do
    step = described_class.grade_steps(
      config: { "database_prepare" => false },
      default_failures: "strict"
    ).first

    expect(step.run).not_to include("bin/rails db:test:prepare")
  end

  it "marks coverage-capable commands when coverage is enabled" do
    full, focused, ci = described_class.grade_steps(
      config: { "coverage" => true },
      default_failures: "strict"
    )

    # Coverage instruments the review entry only -- it is the one phase whose
    # workflows run a coverage_analyze step. Landing and ci would pay for an
    # artifact nothing reads, and at landing that cost comes out of the
    # per-grader deadline a merge train has to clear.
    expect(focused.run).to include("COVERAGE=true")
    expect(focused.metadata["coverage_outputs"]).to eq([
      { "artifact" => "coverage/.resultset.json", "format" => "simplecov" },
      { "artifact" => "coverage/lcov.info", "format" => "lcov" }
    ])
    expect(focused.metadata.dig("filter_capabilities", "coverage")).to be(true)

    [ full, ci ].each do |step|
      expect(step.run).to include("COVERAGE=false")
      expect(step.run).not_to include("COVERAGE=true")
      expect(step.metadata["coverage_outputs"]).to eq([])
      expect(step.metadata.dig("filter_capabilities", "coverage")).to be(false)
    end
  end

  it "leaves a fixed_full_path entry uninstrumented unless it serves the review phase" do
    landing_only = described_class.grade_steps(
      config: { "coverage" => true, "fixed_full_path" => true, "paths" => %w[spec/models], "phases" => %w[landing] },
      default_failures: "strict"
    ).sole

    expect(landing_only.run).to include("COVERAGE=false")
    expect(landing_only.metadata["coverage_outputs"]).to eq([])

    with_review = described_class.grade_steps(
      config: { "coverage" => true, "fixed_full_path" => true, "paths" => %w[spec/models], "phases" => %w[review landing] },
      default_failures: "strict"
    ).sole

    expect(with_review.run).to include("COVERAGE=true")
    expect(with_review.metadata["coverage_outputs"]).not_to be_empty
  end

  it "embeds a focused-file selector script that survives shell parsing as valid Ruby" do
    focused_step = described_class.grade_steps(config: {}, default_failures: "strict").second

    argv = Shellwords.split(focused_step.run)
    selector_script = argv[argv.index("-e") + 1]

    expect { RubyVM::InstructionSequence.compile(selector_script) }.not_to raise_error
  end
end

RSpec.describe Ruby::RspecGraderType, "CI variant" do
  it "declares that its CI variant supersedes the full variant, and nothing else does" do
    steps = described_class.grade_steps(config: { "type" => "rspec", "name" => "rspec", "phases" => %w[review landing ci] }, default_failures: "strict")

    expect(steps.to_h { |step| [ step.name, step.metadata["supersedes"] ] }).to eq("rspec" => nil, "rspec-focused" => nil, "rspec-ci" => "rspec")
  end
end
