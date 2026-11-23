require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe CognitiveReview::ReviewContributions do
  subject(:provider) { described_class }
  let(:contexts) { %i[post_implementation_review_providers diff_review_annotation_providers].index_with { Syrus::Plugin::Context::ReviewContributionContext.new(enabled: false) } }
  it_behaves_like "a valid review provider", plugin: "cognitive_review", provider: "CognitiveReview::ReviewContributions",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
