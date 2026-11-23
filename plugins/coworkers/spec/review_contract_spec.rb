require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Coworkers::ReviewContributions do
  subject(:provider) { described_class }
  let(:contexts) { %i[reviewer_target_providers review_context_contributors review_presentation_contributors review_gates].index_with { Syrus::Plugin::Context::ReviewContributionContext.new(enabled: false) } }
  it_behaves_like "a valid review provider", plugin: "coworkers", provider: "Coworkers::ReviewContributions",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
