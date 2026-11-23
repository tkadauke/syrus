require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe GitMirror::SourceHostServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[repository_content_provider workspace_git_transport].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[repository_content_provider workspace_git_transport].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid source_host provider", plugin: "git_mirror", provider: "GitMirror::SourceHostServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
