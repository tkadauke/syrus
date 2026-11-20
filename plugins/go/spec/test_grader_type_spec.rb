require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe Go::TestGraderType do
  it "registers the go-test type name" do
    expect(described_class.type_name).to eq("go-test")
  end

  it "expands to a root Go test grader" do
    step = described_class.grade_steps(config: {}, default_failures: "strict").first

    expect(step).to have_attributes(
      name: "go-tests",
      run: "mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5,
      when_files_changed: [ "**/*.go", "go.mod", "go.sum", "Makefile" ]
    )
    expect(step.metadata).to include(
      "grader_type" => "go-test",
      "grader_framework" => "go",
      "grader_mode" => "test"
    )
  end

  it "runs nested module paths from the repository root" do
    step = described_class.grade_steps(
      config: { "_syrus_project_path" => "plugins/example", "path" => "cli" },
      default_failures: "strict"
    ).first

    expect(step.run).to eq(
      "mise exec go@1.26.5 -- sh -c 'cd plugins/example/cli && { go list ./... >/dev/null 2>&1 || export GOWORK=off; } && go test ./...'"
    )
    expect(step.when_files_changed).to eq([ "cli/**/*.go", "cli/go.mod", "cli/go.sum", "cli/Makefile" ])
  end

  # Regression: the repository's go.work deliberately leaves plugin CLI
  # modules out, and `go test ./...` inside such a module fails before
  # testing anything -- the credential_store CLI tests went unrun on main.
  describe "a nested module and the repository's go.work" do
    def run_generated(module_in_workspace:)
      Dir.mktmpdir("go-grader") do |dir|
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p([ bin, File.join(dir, "plugins/example/cli") ])
        File.write(File.join(bin, "mise"), "#!/usr/bin/env bash\nshift 3\nexec \"$@\"\n")
        File.write(File.join(bin, "go"), <<~BASH)
          #!/usr/bin/env bash
          if [ "$1" = "list" ]; then
            [ -n "$IN_WORKSPACE" ] || [ "${GOWORK:-}" = "off" ]
            exit $?
          fi
          echo "go $* GOWORK=${GOWORK:-workspace}" > "#{dir}/trace"
        BASH
        FileUtils.chmod("+x", Dir[File.join(bin, "*")])
        step = described_class.grade_steps(config: { "_syrus_project_path" => "plugins/example", "path" => "cli" }, default_failures: "strict").first
        env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "IN_WORKSPACE" => module_in_workspace ? "1" : nil }
        _out, status = Open3.capture2e(env, "bash", "-c", step.run, chdir: dir)
        [ status, File.read(File.join(dir, "trace")).strip ]
      end
    end

    it "tests a module the workspace leaves out on its own" do
      status, trace = run_generated(module_in_workspace: false)

      expect(status).to be_success
      expect(trace).to eq("go test ./... GOWORK=off")
    end

    it "keeps the workspace for a module that is part of it" do
      status, trace = run_generated(module_in_workspace: true)

      expect(status).to be_success
      expect(trace).to eq("go test ./... GOWORK=workspace")
    end
  end

  it "passes dependencies and timeout through" do
    step = described_class.grade_steps(
      config: { "deps" => [ "//cli:grade/go-tests" ], "timeout_minutes" => 8, "required" => false },
      default_failures: "strict"
    ).first

    expect(step.deps).to eq([ "//cli:grade/go-tests" ])
    expect(step.timeout_minutes).to eq(8)
    expect(step.required).to be(false)
  end

  it "defaults to a Go test display name and honors an explicit override" do
    default_step = described_class.grade_steps(config: {}, default_failures: "strict").first
    expect(default_step.display_name).to eq("Go test")

    overridden_step = described_class.grade_steps(config: { "display_name" => "Go CLI tests" }, default_failures: "strict").first
    expect(overridden_step.display_name).to eq("Go CLI tests")
  end
end
