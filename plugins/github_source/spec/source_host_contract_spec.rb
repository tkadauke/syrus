require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusGithubSource::SourceHostServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[input_source source_control_provider].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[input_source source_control_provider].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid source_host provider", plugin: "github_source", provider: "SyrusGithubSource::SourceHostServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
