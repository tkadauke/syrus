require "rails_helper"
require "shellwords"

RSpec.describe JavaScript::VitestGraderType do
  it "registers the vitest type name" do
    expect(described_class.type_name).to eq("vitest")
  end

  it "produces a focused command whose ruby -e script survives squish as one shell word" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").second
    tokens = Shellwords.split(step.run)

    e_index = tokens.index("-e")
    expect(e_index).not_to be_nil

    script_arg = tokens[e_index + 1]
    expect(script_arg).to start_with("base = ")
    expect(script_arg).to include("puts changed.uniq.sort.select")
    # A regression in how the multi-line selector script is escaped before
    # `.squish` runs on the surrounding heredoc would split it into several
    # separate `ruby -e` arguments instead of one -- assert there's exactly
    # one token immediately after -e that is a full, valid Ruby program.
    expect(tokens[e_index + 2]).to eq(">")
    expect { RubyVM::InstructionSequence.compile(script_arg) }.not_to raise_error
  end

  it "expands to typed focused review, full landing, and ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[vitest vitest-focused vitest-ci])
    expect(steps.first.run).to include("run_vitest run app/frontend src test tests __tests__")
    expect(steps.first.run).to include("run_package_script typecheck")
    expect(steps.first.phases).to eq(%w[landing])
    expect(steps.first.junit_output).to eq(".syrus/grade-output/vitest-junit.xml")
    expect(steps.first.base_retry).to eq(SyrusYml::BaseRetry.new(strategy: "plugin", command: nil))
    expect(steps.first.metadata).to include(
      "grader_type" => "vitest",
      "grader_framework" => "vitest",
      "grader_mode" => "full"
    )

    expect(steps.second.run).to include(".syrus/vitest-focused-files")
    expect(steps.second.run).to include("run_vitest related --run --passWithNoTests")
    expect(steps.second.phases).to eq(%w[review])
    expect(steps.second.when_files_changed).to include("**/*.js", "**/*.jsx", "**/*.ts", "**/*.tsx")
    expect(steps.second.when_files_changed).not_to include("app/frontend/**/*.ts", "desktop/src/**/*.tsx")
    expect(steps.second.metadata["grader_mode"]).to eq("focused")

    expect(steps.third.run).to include("run_vitest run app/frontend src test tests __tests__")
    expect(steps.third.phases).to eq(%w[ci])
    expect(steps.third.metadata["grader_mode"]).to eq("ci")
  end

  it "uses configured project scope for every generated grader" do
    steps = described_class.grade_steps(
      config: { "when_files_changed" => [ "app/frontend/**/*.ts", "app/frontend/**/*.tsx" ] },
      default_failures: "strict"
    )

    expect(steps.map(&:when_files_changed)).to eq([
      [ "app/frontend/**/*.ts", "app/frontend/**/*.tsx" ],
      [ "app/frontend/**/*.ts", "app/frontend/**/*.tsx" ],
      [ "app/frontend/**/*.ts", "app/frontend/**/*.tsx" ]
    ])
  end

  it "uses root-relative test paths and unique artifacts for nested projects" do
    steps = described_class.grade_steps(
      config: { "_syrus_project_path" => "plugins/example" },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("run_vitest run plugins/example/app/frontend plugins/example/src")
    expect(steps.first.junit_output).to eq(".syrus/grade-output/plugins-example-vitest-junit.xml")
    expect(steps.second.run).to include("plugins/example")
    expect(steps.second.junit_output).to eq(".syrus/grade-output/plugins-example-vitest-focused-junit.xml")
    expect(steps.first.when_files_changed).to include("**/*.ts", "package.json")
  end

  it "uses configured test paths for full and ci modes" do
    steps = described_class.grade_steps(
      config: { "paths" => [ "app/frontend", "plugins/*/app/frontend" ] },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("run_vitest run app/frontend plugins/\\*/app/frontend")
    expect(steps.second.run).to include("run_vitest related --run --passWithNoTests")
    expect(steps.third.run).to include("run_vitest run app/frontend plugins/\\*/app/frontend")
  end

  it "keeps the focused selector as valid Ruby after shell escaping" do
    command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
    script_arg = command.match(/ruby -e (?<script>.+?) > \.syrus\/vitest-focused-files/m)[:script]
    script = Shellwords.split(script_arg).sole

    expect { RubyVM::InstructionSequence.compile(script) }.not_to raise_error
    expect(script).to include("exit 0 unless base\nscope =")
  end

  it "passes configured target dependencies through to every generated grader" do
    steps = described_class.grade_steps(
      config: { "deps" => [ "//plugins/browser:grade/vitest" ] },
      default_failures: "strict"
    )

    expect(steps.map(&:deps)).to eq([
      [ "//plugins/browser:grade/vitest" ],
      [ "//plugins/browser:grade/vitest" ],
      [ "//plugins/browser:grade/vitest" ]
    ])
  end

  it "allows a custom name prefix, timeout, and required flag" do
    steps = described_class.grade_steps(
      config: { "name" => "frontend", "required" => false, "timeout_minutes" => 20 },
      default_failures: "strict"
    )

    expect(steps.map(&:name)).to eq(%w[frontend frontend-focused frontend-ci])
    expect(steps.map(&:required)).to eq([ false, false, false ])
    expect(steps.map(&:timeout_minutes)).to eq([ 20, 20, 20 ])
  end

  it "supports per-mode timeout overrides" do
    steps = described_class.grade_steps(
      config: { "timeout_minutes" => 20, "focused_timeout_minutes" => 5 },
      default_failures: "strict"
    )

    expect(steps.map { |step| [ step.name, step.timeout_minutes ] }).to eq([
      [ "vitest", 20 ],
      [ "vitest-focused", 5 ],
      [ "vitest-ci", 20 ]
    ])
  end

  it "can disable typecheck and enable coverage" do
    step = described_class.grade_steps(
      config: { "typecheck" => false, "coverage" => true },
      default_failures: "strict"
    ).first

    expect(step.run).not_to include("run_package_script typecheck")
    expect(step.run).to include("--coverage")
    expect(step.metadata["coverage_outputs"]).to eq([
      { "artifact" => "coverage/lcov.info", "format" => "lcov" }
    ])
    expect(step.metadata.dig("filter_capabilities", "typecheck")).to be(false)
  end
end
