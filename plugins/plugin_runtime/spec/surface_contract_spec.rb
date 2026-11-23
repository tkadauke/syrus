require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe PluginRuntime::Surface do
  subject(:provider) { described_class }

  let(:contexts) do
    context = Syrus::Plugin::Context::SurfaceContext.new(enabled: false)
    Syrus::Plugin::Family.fetch(:surface).capabilities.keys.index_with { context }
  end

  it_behaves_like "a valid surface provider",
    plugin: "plugin_runtime", provider: "PluginRuntime::Surface",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
