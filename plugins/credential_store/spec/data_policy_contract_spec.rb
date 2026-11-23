require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe CredentialStore::DataPolicy do
  subject(:provider) { described_class }
  let(:contexts) { %i[purge_contributors].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[purge_contributors].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid data_policy provider", plugin: "credential_store", provider: "CredentialStore::DataPolicy",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
