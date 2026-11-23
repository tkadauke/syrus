require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe VideoWalkthroughs::ChatIntegration do
  subject(:provider) { described_class }
  let(:contexts) { Syrus::Plugin::Family.fetch(:chat_integration).capabilities.keys.index_with { Syrus::Plugin::Context::ChatIntegrationContext.new(enabled: false) } }
  it_behaves_like "a valid chat_integration provider", plugin: "video_walkthroughs", provider: "VideoWalkthroughs::ChatIntegration",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
