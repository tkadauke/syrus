require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe AgentInsights::Lifecycle do
  subject(:provider) { described_class }
  let(:contexts) { %i[domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid lifecycle provider", plugin: "agent_insights", provider: "AgentInsights::Lifecycle",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
