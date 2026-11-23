require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusAgyAgent::AgentRuntimeServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[agent_provider chat_provider].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[agent_provider chat_provider].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid agent_runtime provider", plugin: "agy_agent", provider: "SyrusAgyAgent::AgentRuntimeServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
