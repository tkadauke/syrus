require "rails_helper"

RSpec.describe Ruby::RspecGraderType do
  it "registers the rspec type name" do
    expect(described_class.type_name).to eq("rspec")
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
