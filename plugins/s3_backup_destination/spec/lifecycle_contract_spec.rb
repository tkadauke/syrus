require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe S3BackupDestination::Lifecycle do
  subject(:provider) { described_class }
  let(:contexts) { %i[domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new } }
  let(:decline_contexts) { %i[domain_subscribers].index_with { Syrus::Plugin::Context::HookContext.new(enabled: false) } }
  it_behaves_like "a valid lifecycle provider", plugin: "s3_backup_destination", provider: "S3BackupDestination::Lifecycle",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
