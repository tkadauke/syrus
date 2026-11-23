require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusCodexAgent::Surface do
  subject(:provider) { described_class }

  let(:contexts) do
    context = Syrus::Plugin::Context::SurfaceContext.new(enabled: false)
    Syrus::Plugin::Family.fetch(:surface).capabilities.keys.index_with { context }
  end

  it_behaves_like "a valid surface provider",
    plugin: "codex_agent", provider: "SyrusCodexAgent::Surface",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
