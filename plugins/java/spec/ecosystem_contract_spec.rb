require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Java::Ecosystem do
  subject { described_class }

  let(:repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: Rails.root.to_s) }
  let(:empty_repo_context) { Syrus::Plugin::Context::RepoContext.new(repo_path: nil) }
  let(:job_context) { Syrus::Plugin::Context::JobContext.new(repository: Object.new, job: nil) }
  let(:empty_job_context) { Syrus::Plugin::Context::JobContext.new(repository: nil, job: nil) }

  it_behaves_like "a valid ecosystem provider",
    plugin: "java", provider: "Java::Ecosystem",
    contexts: -> { { detect_prepare: repo_context, prompt_context: job_context, review_criteria: repo_context } },
    decline_contexts: lambda {
      { detect_prepare: empty_repo_context, prompt_context: empty_job_context, review_criteria: empty_repo_context }
    }
end

RSpec.describe Java::GradleEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "java", provider: "Java::GradleEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}) } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: nil) } }
end

RSpec.describe Java::MavenEcosystem do
  subject { described_class }

  it_behaves_like "a valid ecosystem provider",
    plugin: "java", provider: "Java::MavenEcosystem",
    contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: {}) } },
    decline_contexts: -> { { grader_types: Syrus::Plugin::Context::GraderContext.new(config: nil) } }
end
