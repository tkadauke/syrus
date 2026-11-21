require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Ruby::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) }
  let(:empty_workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) }
  let(:coverage_context) do
    Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: Rails.root.to_s,
      artifact_path: Rails.root.join("spec/fixtures/simplecov/resultset.json"),
      format_hint: "simplecov"
    )
  end
  let(:grader_context) { Syrus::Plugin::Context::GraderContext.new(name: "other", command: "true", workspace_path: Rails.root.to_s) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ruby",
    provider: "Ruby::Ecosystem",
    contexts: lambda {
      {
        detect_prepare: repo_context,
        grade_candidates: repo_context,
        grader_diagnostics: grader_context,
        review_criteria: repo_context,
        autofix: workspace_context,
        dependency_audit: workspace_context,
        focused_tests: grader_context,
        analyze_coverage: coverage_context,
        affected_tests: workspace_context
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
        focused_tests: grader_context,
        analyze_coverage: empty_workspace_context,
        affected_tests: empty_workspace_context
      }
    }

  it "routes grade detection through the repository context" do
    expect(Ruby::GradeDetector).to receive(:grade_candidates).with("/repo").and_return([ { name: "rspec" } ])

    result = described_class.grade_candidates(Syrus::Plugin::Context::RepoContext.new(repo_path: "/repo"))

    expect(result).to eq([ { name: "rspec" } ])
  end

  it "collects both grader diagnostic providers through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(name: "rspec", command: "bin/rspec", workspace_path: "/repo")
    expected = { name: "rspec", command: "bin/rspec", workspace_path: "/repo" }
    expect(Ruby::GraderAugmentor).to receive(:augment_grader_failure).with(**expected).and_return([ "rspec detail" ])
    expect(Ruby::RubocopGraderAugmentor).to receive(:augment_grader_failure).with(**expected).and_return([ "rubocop detail" ])

    expect(described_class.grader_diagnostics(context)).to eq([ "rspec detail", "rubocop detail" ])
  end

  it "returns the dependency-audit plan selected by changed files" do
    context = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/repo", changed_files: [ "nested/Gemfile.lock" ]
    )
    expect(Ruby::BundlerAuditCommand).to receive(:audit_command)
      .with(workspace_path: "/repo").and_return("bundle-audit check --update")

    plan = described_class.dependency_audit(context)

    expect(plan.to_h).to eq(lockfiles: [ "Gemfile.lock" ], command: "bundle-audit check --update", label: "Ruby")
  end

  it "routes focused-test fields through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(
      name: "rspec", command: "bin/rspec", failed_cases: [ { "file_path" => "spec/a_spec.rb" } ],
      base_retry: { "strategy" => "plugin" }, project_path: "component", operation: :command
    )
    expect(Ruby::FocusedTestCommand).to receive(:command_for).with(
      grader_name: "rspec", grader_command: "bin/rspec",
      failed_cases: [ { "file_path" => "spec/a_spec.rb" } ],
      base_retry: { "strategy" => "plugin" }, project_path: "component"
    ).and_return("bundle exec rspec spec/a_spec.rb")

    expect(described_class.focused_tests(context)).to eq("bundle exec rspec spec/a_spec.rb")
  end

  it "routes coverage artifacts through the workspace context" do
    artifact = Pathname("/repo/coverage/resultset.json")
    context = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/repo", artifact_path: artifact, format_hint: "simplecov"
    )
    expect(Ruby::SimpleCovAnalyzer).to receive(:can_parse?)
      .with(output_path: artifact, format_hint: "simplecov").and_return(true)
    expect(Ruby::SimpleCovAnalyzer).to receive(:call)
      .with(output_path: artifact, format_hint: "simplecov").and_return({ lines: 90.0 })

    expect(described_class.analyze_coverage(context)).to eq(lines: 90.0)
  end

  it "routes affected-test fields through the workspace context" do
    context = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/repo", changed_files: [ "app/models/widget.rb" ]
    )
    expect(Ruby::AffectedTestAnalyzer).to receive(:affected_files)
      .with(repo_path: "/repo", changed_files: [ "app/models/widget.rb" ])
      .and_return([ "spec/models/widget_spec.rb" ])

    expect(described_class.affected_tests(context)).to eq([ "spec/models/widget_spec.rb" ])
  end
end

RSpec.describe Ruby::RspecEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ruby", provider: "Ruby::RspecEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }

  it "routes typed grader configuration through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(config: { "required" => true }, default_failures: "strict")
    expect(Ruby::RspecGraderType).to receive(:grade_steps)
      .with(config: { "required" => true }, default_failures: "strict").and_return([ :rspec_step ])

    expect(described_class.grader_types(context)).to eq([ :rspec_step ])
  end
end

RSpec.describe Ruby::MinitestEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "ruby", provider: "Ruby::MinitestEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }

  it "routes typed grader configuration through the grader context" do
    context = Syrus::Plugin::Context::GraderContext.new(config: { "required" => false }, default_failures: "warn")
    expect(Ruby::MinitestGraderType).to receive(:grade_steps)
      .with(config: { "required" => false }, default_failures: "warn").and_return([ :minitest_step ])

    expect(described_class.grader_types(context)).to eq([ :minitest_step ])
  end
end
