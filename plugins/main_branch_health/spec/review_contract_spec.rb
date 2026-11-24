require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe MainBranchHealth::ReviewContributions do
  subject(:provider) { described_class }
  let(:contexts) { %i[adjudicators].index_with { Syrus::Plugin::Context::ReviewContributionContext.new(enabled: false) } }
  it_behaves_like "a valid review provider", plugin: "main_branch_health", provider: "MainBranchHealth::ReviewContributions",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
