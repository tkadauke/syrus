require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe MetricsDashboard::Surface do
  subject(:provider) { described_class }

  let(:contexts) do
    context = Syrus::Plugin::Context::SurfaceContext.new(enabled: false)
    Syrus::Plugin::Family.fetch(:surface).capabilities.keys.index_with { context }
  end

  it_behaves_like "a valid surface provider",
    plugin: "metrics_dashboard", provider: "MetricsDashboard::Surface",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
