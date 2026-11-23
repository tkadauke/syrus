require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe GithubHost::SourceHostServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[repository_content_provider].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[repository_content_provider].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid source_host provider", plugin: "github_host", provider: "GithubHost::SourceHostServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
