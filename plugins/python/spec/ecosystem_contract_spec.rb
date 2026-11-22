require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Python::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) }
  let(:empty_workspace_context) { Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) }
  let(:grader_context) { Syrus::Plugin::Context::GraderContext.new(name: "pytest", command: "pytest", workspace_path: Rails.root.to_s) }
  let(:job_context) { Syrus::Plugin::Context::JobContext.new(repository: Object.new, job: nil) }
  let(:empty_job_context) { Syrus::Plugin::Context::JobContext.new(repository: nil, job: nil) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "python", provider: "Python::Ecosystem",
    contexts: lambda {
      {
        detect_prepare: repo_context, grader_diagnostics: grader_context, review_criteria: repo_context,
        prompt_context: job_context, dependency_audit: workspace_context
      }
    },
    decline_contexts: lambda {
      {
        detect_prepare: empty_repo_context, grader_diagnostics: grader_context, review_criteria: empty_repo_context,
        prompt_context: empty_job_context,
        dependency_audit: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil, changed_files: [ "other.lock" ])
      }
    }
end

RSpec.describe Python::RuffEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "python", provider: "Python::RuffEcosystem",
    contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) } },
    decline_contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) } }
end

RSpec.describe Python::BlackEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "python", provider: "Python::BlackEcosystem",
    contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: Rails.root.to_s) } },
    decline_contexts: -> { { autofix: Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: nil) } }
end
