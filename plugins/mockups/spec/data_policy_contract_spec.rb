require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Mockups::DataPolicy do
  subject(:provider) { described_class }
  let(:contexts) { %i[preview_panel_retentions].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[preview_panel_retentions].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid data_policy provider", plugin: "mockups", provider: "Mockups::DataPolicy",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
