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
end
