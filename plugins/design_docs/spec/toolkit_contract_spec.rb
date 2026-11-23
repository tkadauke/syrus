require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe DesignDocs::Toolkit do
  subject(:provider) { described_class }

  let(:contexts) do
    discovery = Syrus::Plugin::Context::ToolkitDiscoveryContext.new(enabled: false)
    credentials = Syrus::Plugin::Context::ToolkitCredentialContext.new(enabled: false)
    run = Syrus::Plugin::Context::ToolkitRunContext.new(run: nil, role: nil, enabled: false)
    {
      workflow_tools: discovery,
      chat_tools: discovery,
      permissions: discovery,
      run_context: run,
      credential_probes: credentials,
      secret_extractors: credentials
    }
  end

  it_behaves_like "a valid toolkit provider",
    plugin: "design_docs", provider: "DesignDocs::Toolkit",
    contexts: -> { contexts }, decline_contexts: -> { contexts }
end
