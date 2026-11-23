require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe ContainerExecution::ExecutionBackendServices do
  subject(:provider) { described_class }
  let(:contexts) { %i[execution_backend].index_with { Syrus::Plugin::Context::ServiceContext.new } }
  let(:decline_contexts) { %i[execution_backend].index_with { Syrus::Plugin::Context::ServiceContext.new(enabled: false) } }

  it_behaves_like "a valid execution_backend provider", plugin: "container_execution", provider: "ContainerExecution::ExecutionBackendServices",
    contexts: -> { contexts }, decline_contexts: -> { decline_contexts }
end
