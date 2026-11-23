require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusBrowser::RuntimeSessionServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[runtime_session_provider].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[runtime_session_provider].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid runtime_session provider", plugin: "browser", provider: "SyrusBrowser::RuntimeSessionServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
