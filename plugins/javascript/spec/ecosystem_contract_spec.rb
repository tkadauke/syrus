require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe JavaScript::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) }
  let(:empty_workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) }
  let(:grader_context) { Syrus::Plugin::Context::GraderContext.new(name: "other", command: "true", workspace_path: Rails.root.to_s) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "javascript",
    provider: "JavaScript::Ecosystem",
    contexts: lambda {
      {
        detect_prepare: repo_context,
        grade_candidates: repo_context,
        grader_diagnostics: grader_context,
        review_criteria: repo_context,
        autofix: workspace_context,
        dependency_audit: workspace_context,
        focused_tests: grader_context
      }
    },
    decline_contexts: lambda {
      {
        detect_prepare: empty_repo_context,
        grade_candidates: empty_repo_context,
        grader_diagnostics: grader_context,
        review_criteria: empty_repo_context,
        autofix: empty_workspace_context,
        dependency_audit: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil, changed_files: [ "other.lock" ]),
        focused_tests: grader_context
      }
    }

  it "routes grade detection through the repository context" do
    expect(JavaScript::GradeDetector).to receive(:grade_candidates).with("/repo").and_return([ { name: "vitest" } ])

    result = described_class.grade_candidates(Syrus::Plugin::Context::RepoContext.new(repo_path: "/repo"))

    expect(result).to eq([ { name: "vitest" } ])
  end

  it "routes grader diagnostics through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(name: "eslint", command: "npx eslint", workspace_path: "/repo")
    expect(JavaScript::EslintGraderAugmentor).to receive(:augment_grader_failure).with(
      name: "eslint", command: "npx eslint", workspace_path: "/repo"
    ).and_return([ "eslint detail" ])

    expect(described_class.grader_diagnostics(context)).to eq([ "eslint detail" ])
  end

  it "returns the dependency-audit plan selected by changed files" do
    context = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/repo", changed_files: [ "nested/package-lock.json" ]
    )
    expect(JavaScript::DependencyAuditCommand).to receive(:audit_command)
      .with(workspace_path: "/repo").and_return("npm audit --json")

    plan = described_class.dependency_audit(context)

    expect(plan.to_h).to eq(
      lockfiles: [ "yarn.lock", "pnpm-lock.yaml", "package-lock.json" ],
      command: "npm audit --json", label: "JavaScript"
    )
  end

  it "routes focused-test fields through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(
      name: "vitest", command: "npx vitest run", failed_cases: [ { "file_path" => "src/a.test.ts" } ],
      base_retry: { "strategy" => "plugin" }, project_path: "component", operation: :command
    )
    expect(JavaScript::FocusedTestCommand).to receive(:command_for).with(
      grader_name: "vitest", grader_command: "npx vitest run",
      failed_cases: [ { "file_path" => "src/a.test.ts" } ],
      base_retry: { "strategy" => "plugin" }, project_path: "component"
    ).and_return("npx vitest run src/a.test.ts")

    expect(described_class.focused_tests(context)).to eq("npx vitest run src/a.test.ts")
  end
end

RSpec.describe JavaScript::PrettierEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "javascript", provider: "JavaScript::PrettierEcosystem",
    contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) } },
    decline_contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) } }
end

RSpec.describe JavaScript::VitestEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "javascript", provider: "JavaScript::VitestEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }

  it "routes typed grader configuration through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(config: { "required" => true }, default_failures: "strict")
    expect(JavaScript::VitestGraderType).to receive(:grade_steps)
      .with(config: { "required" => true }, default_failures: "strict").and_return([ :vitest_step ])

    expect(described_class.grader_types(context)).to eq([ :vitest_step ])
  end
end
