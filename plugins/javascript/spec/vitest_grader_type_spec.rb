require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe JavaScript::VitestGraderType do
  it "registers the vitest type name" do
    expect(described_class.type_name).to eq("vitest")
  end

  it "generates a focused command whose embedded ruby selector survives .squish intact" do
    Dir.mktmpdir do |dir|
      run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
      run_git.call("init", "-q", "-b", "main")
      run_git.call("config", "user.email", "test@example.com")
      run_git.call("config", "user.name", "Test")
      run_git.call("config", "commit.gpgsign", "false")
      File.write(File.join(dir, "README.md"), "base\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "base")
      run_git.call("checkout", "-q", "-b", "feature")
      FileUtils.mkdir_p(File.join(dir, "app/frontend/components"))
      File.write(File.join(dir, "app/frontend/components/Widget.tsx"), "export const Widget = () => null;\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "feature")

      command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
      selector = command[command.index("ruby -e ")...command.index(" > .syrus/vitest-focused-files")]

      stdout, stderr, status = Open3.capture3("bash", "-c", selector, chdir: dir)

      expect(status).to be_success, "expected the focused-file selector to run without a shell/ruby syntax error, got:\n#{stderr}"
      expect(stdout).to include("app/frontend/components/Widget.tsx")
    end
  end

  it "expands to typed focused review, full landing, and ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[vitest vitest-focused vitest-ci])
    expect(steps.first.run).to include("run_vitest run app/frontend src test tests __tests__")
    expect(steps.first.run).to include("run_package_script typecheck")
    expect(steps.first.run).to include("[ ! -x node_modules/.bin/vitest ] || { typecheck_uses_tsc && [ ! -x node_modules/.bin/tsc ]; }; then npm install")
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
    expect(steps.second.run).to include("[ ! -x node_modules/.bin/vitest ]; then npm install")
    expect(steps.second.phases).to eq(%w[review])
    expect(steps.second.when_files_changed).to include("**/*.js", "**/*.jsx", "**/*.ts", "**/*.tsx")
    expect(steps.second.when_files_changed).not_to include("app/frontend/**/*.ts", "desktop/src/**/*.tsx")
    expect(steps.second.metadata["grader_mode"]).to eq("focused")

    expect(steps.third.run).to include("run_vitest run app/frontend src test tests __tests__")
    expect(steps.third.phases).to eq(%w[ci])
    expect(steps.third.metadata["grader_mode"]).to eq("ci")
  end

  it "synthesizes mode-aware operator-facing display names by default" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:display_name)).to eq([ "Vitest", "Vitest (focused)", "Vitest (CI)" ])
  end

  it "lets an explicit display_name override the generated default" do
    steps = described_class.grade_steps(config: { "display_name" => "Frontend suite" }, default_failures: "strict")

    expect(steps.map(&:display_name)).to eq([ "Frontend suite" ] * 3)
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

  it "embeds a focused-file selector script that survives shell parsing as valid Ruby" do
    focused_step = described_class.grade_steps(config: {}, default_failures: "strict").second

    argv = Shellwords.split(focused_step.run)
    selector_script = argv[argv.index("-e") + 1]

    expect { RubyVM::InstructionSequence.compile(selector_script) }.not_to raise_error
  end
end
