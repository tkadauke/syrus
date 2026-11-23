require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Coworkers::DataPolicy do
  subject(:provider) { described_class }
  let(:contexts) { %i[retention_policies].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[retention_policies].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid data_policy provider", plugin: "coworkers", provider: "Coworkers::DataPolicy",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
