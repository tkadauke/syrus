require "rails_helper"

# Behavioral coverage for the remaining provider families adopted by the
# invocation boundary. Each example exercises the public surrounding operation:
# a broken provider declines, later/core behavior survives, and health records
# the failure. Individual services retain their detailed happy-path specs.
RSpec.describe "remaining runtime plugin invocation sites", :reset_plugin_registry do
  let(:health) { Syrus::PluginRuntimeHealth.new }

  around do |example|
    previous = Syrus::PluginInvocation.runtime_health
    Syrus::PluginInvocation.runtime_health = health
    example.run
  ensure
    Syrus::PluginInvocation.runtime_health = previous
  end

  def providers_for(extension_point, providers)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(extension_point).and_return(providers)
  end

  def expect_failure(extension_point, operation)
    expect(health.failures.last).to have_attributes(
      extension_point: extension_point.to_s, operation: operation.to_s
    )
  end

  it "keeps a chat turn alive when finalization fails" do
    provider = Class.new do
      def self.after_chat_turn(**) = raise("finalizer failed")
    end
    providers_for(:chat_turn_finalizer, [ provider ])
    chat = ChatSession.create!(user: Factories.user)
    message = chat.messages.create!(role: "user", content: { "text" => "hello" })
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, message)
    job.instance_variable_set(:@turn_completed_successfully, true)

    expect { job.send(:finalize_plugin_turns!) }.to change { chat.messages.count }.by(1)
    expect_failure(:chat_turn_finalizer, :after_chat_turn)
  end

  it "falls back when workspace selection fails" do
    provider = Class.new do
      def self.applies_to?(**) = raise("workspace failed")
    end
    providers_for(:chat_workspace_lifecycle, [ provider ])
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, instance_double(ChatSession))

    expect(job.send(:plugin_workspace_lifecycle)).to be_nil
    expect_failure(:chat_workspace_lifecycle, :applies_to)
  end

  it "uses the normal chat turn when orientation fails" do
    provider = Class.new do
      def self.chat_turn_orientation(**) = raise("orientation failed")
    end
    providers_for(:chat_turn_orientation, [ provider ])
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, instance_double(ChatSession))
    job.instance_variable_set(:@user_message, instance_double(ChatMessage))

    expect(job.send(:plugin_turn_orientation, user_note: "hello")).to be_nil
    expect_failure(:chat_turn_orientation, :chat_turn_orientation)
  end

  it "uses the default turn lifecycle when selection fails" do
    provider = Class.new do
      def self.applies_to?(**) = raise("lifecycle failed")
    end
    providers_for(:chat_turn_lifecycle, [ provider ])

    lifecycle = ChatTurnLifecycles.for(chat_session: double, user_message: double)

    expect(lifecycle).to be_a(ChatTurnLifecycles::Default)
    expect_failure(:chat_turn_lifecycle, :applies_to)
  end

  it "omits failing identity contributions" do
    provider = Class.new do
      def self.chat_identities(**) = raise("identity failed")
    end
    providers_for(:chat_identity_provider, [ provider ])

    expect(ChatIdentityContributions.identities(chat_session: double, user: double)).to eq([])
    expect_failure(:chat_identity_provider, :chat_identities)
  end

  it "omits failing media sources" do
    provider = Class.new do
      def self.chat_media_kind = raise("media failed")
    end
    providers_for(:chat_media_source, [ provider ])

    expect(ChatMediaSources.kinds).to eq([ "chat_image" ])
    expect_failure(:chat_media_source, :chat_media_kind)
  end

  it "skips a failing chat provider and finds the next provider" do
    broken = Class.new do
      def self.provider_key = raise("chat provider failed")
    end
    healthy = Class.new do
      def self.provider_key = "healthy"
    end
    providers_for(:chat_provider, [ broken, healthy ])

    expect(ChatProviders.for("healthy")).to eq(healthy)
    expect_failure(:chat_provider, :provider_key)
  end

  it "skips a failing agent provider and finds the next provider" do
    broken = Class.new do
      def self.provider_key = raise("agent provider failed")
    end
    healthy = Class.new do
      def self.provider_key = "healthy"
    end
    providers_for(:agent_provider, [ broken, healthy ])

    expect(AgentProviders.for("healthy")).to eq(healthy)
    expect_failure(:agent_provider, :provider_key)
  end

  it "omits a failing mentionable provider" do
    provider = Class.new do
      def self.find_mentionable(**) = raise("mentionable failed")
    end
    providers_for(:mentionable, [ provider ])

    expect(Mentionables::Resolver.find(kind: "plugin", id: 1)).to be_nil
    expect_failure(:mentionable, :find_mentionable)
  end

  it "omits a failing permission provider" do
    provider = Class.new do
      def self.permission_authorization_adapters = raise("permission failed")
    end
    providers_for(:permission_provider, [ provider ])
    allow(Rails.logger).to receive(:warn)

    expect(Permissions::AuthorizationAdapters.resolve("plugin.action")).to be_nil
    expect_failure(:permission_provider, :permission_authorization_adapters)
  end

  it "omits failing workflow MCP tool discovery" do
    provider = Class.new do
      def self.available_for?(_) = true
      def self.tool_definitions = raise(NotImplementedError, "tools unavailable")
    end
    providers_for(:mcp_tool_set, [ provider ])
    allow(McpToolRegistry).to receive(:summaries).and_return([])

    expect(McpToolUsageRecorder.workflow_tool_names).to eq([])
    expect_failure(:mcp_tool_set, :tool_definitions)
  end

  it "omits failing MCP run-context contributions" do
    provider = Class.new do
      def self.context_attributes(**) = raise("context failed")
    end
    providers_for(:mcp_run_context_contributor, [ provider ])

    attributes = McpToolContext.send(:run_context_attributes, double, AgentRole::WORKFLOW_IMPLEMENT)

    expect(attributes).to eq({})
    expect_failure(:mcp_run_context_contributor, :context_attributes)
  end

  it "isolates a failing inline domain subscriber" do
    provider = Class.new do
      def self.subscriptions = { "step.grader.completed" => :receive_event }
      def self.receive_event(_) = raise("subscriber failed")
    end
    providers_for(:domain_subscriber, [ provider ])

    expect { Syrus::Events.publish("step.grader.completed", run_id: 1) }.not_to raise_error
    expect_failure(:domain_subscriber, :"step.grader.completed")
  end

  it "omits a failing retention provider" do
    provider = Class.new do
      def self.name = "BrokenRetentionProvider"
      def self.retention_definitions = raise("retention failed")
    end
    providers_for(:retention_policy, [ provider ])
    allow(Rails.logger).to receive(:error)

    expect { RetentionPolicyRegistry.definitions }.not_to raise_error
    expect_failure(:retention_policy, :retention_definitions)
  end

  it "reports and omits a failing purge contributor" do
    provider = Class.new do
      def self.purge_report(_) = raise("purge failed")
      def self.to_s = "BrokenPurgeContributor"
    end
    providers_for(:purge_contributor, [ provider ])

    expect(Syrus::PluginPurge.new("absent_plugin").other_data.sole).to include("could not report")
    expect_failure(:purge_contributor, :purge_report)
  end
end
