require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe GlobalSearch::Lifecycle do
  subject(:provider) { described_class }
  let(:contexts) { %i[callback_providers domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[callback_providers domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid lifecycle provider", plugin: "global_search", provider: "GlobalSearch::Lifecycle",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
