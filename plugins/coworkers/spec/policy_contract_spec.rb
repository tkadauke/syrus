require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Coworkers::Policy do
  subject(:provider) { described_class }
  let(:contexts) { %i[job_visibility_restrictions repository_filters].index_with { Syrus::Plugin::Context::PolicyContext.new(enabled: false) } }
  it_behaves_like "a valid policy provider", plugin: "coworkers", provider: "Coworkers::Policy",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
