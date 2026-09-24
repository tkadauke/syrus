require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::RspecGraderType do
  it "registers the rspec type name" do
    expect(described_class.type_name).to eq("rspec")
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

  it "expands to typed focused review, full landing, and ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[rspec rspec-focused rspec-ci])
    expect(steps.first.run).to include("bundle exec rspec")
    expect(steps.first.run).to include("bin/rails db:test:prepare")
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
    script_arg = command.match(/ruby -e (?<script>.+?) > \.syrus\/rspec-focused-files/m)[:script]
    script = Shellwords.split(script_arg).sole

    expect { RubyVM::InstructionSequence.compile(script) }.not_to raise_error
    expect(script).to include("exit 0 unless base\nscope =")
  end

  it "uses configured parallel_rspec for fast and focused modes" do
    steps = described_class.grade_steps(
      config: {
        "parallel_rspec" => {
          "enabled" => true,
          "rspec_modes" => [ "full", "focused" ],
          "processes" => "4",
          "exec_args" => "bin/rspec-worker",
          "prepare_command" => "bundle exec rake parallel:prepare"
        }
      },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("bundle exec parallel_rspec -n 4 --quiet")
    expect(steps.first.run).to include("--exec-args bin/rspec-worker spec")
    expect(steps.first.run).to include("bundle exec rake parallel:prepare")
    expect(steps.first.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~ci_only")
    expect(steps.first.run).to include("RSPEC_OUTPUT_PREFIX=rspec")
    expect(steps.first.run).to include("parallel-rspec-junit")
    expect(steps.second.run).to include("bundle exec parallel_rspec -n 4 --quiet")
    expect(steps.second.run).to include("--exec-args bin/rspec-worker $(cat .syrus/rspec-focused-files)")
    expect(steps.third.run).to include("bundle exec rspec")
    expect(steps.third.run).not_to include("parallel_rspec")
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
    expect(step.run).to include("bundle exec parallel_rspec --quiet")
    expect(step.run).to include("RSPEC_TAG_ARGS=--tag\\ \\~ci_only")
    expect(step.run).to include("RUN_CI_ONLY_SPECS=true bundle exec rspec")
    expect(step.run).to include("--tag ci_only")
    expect(step.run).to include("serial_status")

    status_checks = step.run.match(/if \[ "\$parallel_status" -ne 0 \].*\z/)[0]
    _stdout, stderr, status = Open3.capture3({ "parallel_status" => "0", "serial_status" => "0" }, "bash", "-c", status_checks)
    expect(status).to be_success, "expected the generated extra-serial status checks to run, got:\n#{stderr}"
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

    expect(step.run).to include("bundle exec parallel_rspec -n 2 --quiet")
    expect(step.run).to include("--test-options")
    expect(step.run).to include(".syrus/rspec-json/rspec-")
    expect(step.run).to include(".syrus/grade-output/parallel-rspec-junit/rspec-")
    expect(step.run.scan(/\sspec(?:;|\s)/).length).to eq(1)

    status_checks = step.run.match(/exit "\$parallel_status"\z/)[0]
    _stdout, stderr, status = Open3.capture3({ "parallel_status" => "0" }, "bash", "-c", status_checks)
    expect(status).to be_success, "expected the generated parallel status check to run, got:\n#{stderr}"
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
