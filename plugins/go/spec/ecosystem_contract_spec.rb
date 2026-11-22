require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Go::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) }
  let(:empty_workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "go", provider: "Go::Ecosystem",
    contexts: lambda {
      {
        detect_prepare: repo_context, review_criteria: repo_context, autofix: workspace_context,
        dependency_audit: workspace_context,
        analyze_coverage: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s)
      }
    },
    decline_contexts: lambda {
      {
        detect_prepare: empty_repo_context, review_criteria: empty_repo_context, autofix: empty_workspace_context,
        dependency_audit: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil, changed_files: [ "other.lock" ]),
        analyze_coverage: empty_workspace_context
      }
    }
end

RSpec.describe Go::TestEcosystem do
  subject { described_class }

  it "uses the public grader type name as its dispatch key" do
    expect(described_class.key).to eq(:"go-test")
  end

  it_behaves_like "a valid ecosystem provider",
    plugin: "go", provider: "Go::TestEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}, default_failures: "fail") } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new } }
end
