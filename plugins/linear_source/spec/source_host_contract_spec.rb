require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusLinearSource::SourceHostServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[input_source].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[input_source].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid source_host provider", plugin: "linear_source", provider: "SyrusLinearSource::SourceHostServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
