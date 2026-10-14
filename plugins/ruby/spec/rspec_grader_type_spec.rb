require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::RspecGraderType do
  def focused_selector_from(command)
    script_arg = command.match(/ruby -e (?<script>.+?) > \.syrus\/rspec-focused-files/m)[:script]
    Shellwords.split(script_arg).sole
  end

  def run_generated_rspec_command(command, parallel_status:, serial_status: 0)
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
      }
      yield dir if block_given?
      stdout, stderr, status = Open3.capture3(env, "bash", "-c", command, chdir: dir)
      parallel_args = File.exist?(File.join(dir, "parallel_rspec_args.txt")) ? File.read(File.join(dir, "parallel_rspec_args.txt")) : ""
      [ stdout, stderr, status, parallel_args ]
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

    def run_gate(command, previous_specs:, gate_status: 0, parallel_status: 0)
      Dir.mktmpdir("rspec-grader-gate") do |dir|
        bin_dir = File.join(dir, "bin")
        FileUtils.mkdir_p(bin_dir)
        File.write(File.join(bin_dir, "bundle"), <<~BASH)
          #!/usr/bin/env bash
          case "$1" in
            check|install) exit 0 ;;
            exec)
              shift
              if [ "$1" = "rspec" ]; then echo "GATE_RAN" >> "$TRACE"; exit "${FAKE_GATE_STATUS:-0}"; fi
              "$@"; exit $? ;;
            *) exit 64 ;;
          esac
        BASH
        File.write(File.join(bin_dir, "parallel_rspec"), <<~BASH)
          #!/usr/bin/env bash
          echo "FULL_RAN" >> "$TRACE"
          exit "${FAKE_PARALLEL_RSPEC_STATUS:-0}"
        BASH
        File.write(File.join(bin_dir, "ruby"), "#!/usr/bin/env bash\nexit 0\n")
        FileUtils.chmod("+x", Dir[File.join(bin_dir, "*")])
        trace = File.join(dir, "trace")

        env = {
          "PATH" => "#{bin_dir}:#{ENV.fetch('PATH')}",
          "TRACE" => trace,
          "SYRUS_PREVIOUS_FAILED_SPECS" => previous_specs,
          "FAKE_GATE_STATUS" => gate_status.to_s,
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

    it "still runs the full suite when the gate passes" do
      exitstatus, trace = run_gate(gate_command, previous_specs: "spec/a_spec.rb", gate_status: 0)

      expect(exitstatus).to eq(0)
      expect(trace).to include("GATE_RAN")
      expect(trace).to include("FULL_RAN")
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
    expect(steps.first.run).to include("falling back to parallel_tests default grouping")
    expect(steps.first.run).to include("--exec-args bin/rspec-worker spec")
    expect(steps.first.run).to include("bundle exec rake parallel:prepare")
    expect(steps.first.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~ci_only")
    expect(steps.first.run).to include("RSPEC_OUTPUT_PREFIX=rspec")
    expect(steps.first.metadata["runtime_profile_destination"]).to eq(".syrus/parallel_runtime_rspec.log")
    expect(steps.first.run).to include("parallel-rspec-junit")
    expect(steps.second.run).to include('bundle exec parallel_rspec $parallel_runtime_args -n "$RSPEC_PARALLEL_PROCESSES" --quiet')
    expect(steps.second.run).to include("--exec-args bin/rspec-worker $(cat .syrus/rspec-focused-files)")
    expect(steps.third.run).to include("bundle exec rspec")
    expect(steps.third.run).not_to include("parallel_rspec")
  end

  it "falls back to default parallel_rspec grouping when no runtime profile was materialized" do
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
    expect(stdout).to include("falling back to parallel_tests default grouping")
    expect(parallel_args).not_to include("--group-by runtime")
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

  it "can disable the auto Rails test database prepare hook" do
    step = described_class.grade_steps(
      config: { "database_prepare" => false },
      default_failures: "strict"
    ).first

    expect(step.run).not_to include("bin/rails db:test:prepare")
  end

  it "marks coverage-capable commands when coverage is enabled" do
    step = described_class.grade_steps(
      config: { "coverage" => true },
      default_failures: "strict"
    ).first

    expect(step.run).to include("COVERAGE=true")
    expect(step.metadata["coverage_outputs"]).to eq([
      { "artifact" => "coverage/.resultset.json", "format" => "simplecov" }
    ])
    expect(step.metadata.dig("filter_capabilities", "coverage")).to be(true)
  end

  it "embeds a focused-file selector script that survives shell parsing as valid Ruby" do
    focused_step = described_class.grade_steps(config: {}, default_failures: "strict").second

    argv = Shellwords.split(focused_step.run)
    selector_script = argv[argv.index("-e") + 1]

    expect { RubyVM::InstructionSequence.compile(selector_script) }.not_to raise_error
  end
end
