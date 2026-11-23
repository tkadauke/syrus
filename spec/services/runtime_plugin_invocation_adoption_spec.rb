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

  def failing_family_provider(family, capability, message)
    provider_name = "Failing#{family.to_s.camelize}#{capability.to_s.camelize}Provider"
    stub_const(provider_name, Class.new do
      define_singleton_method(capability) { |_| raise message }
    end)
    provider = Syrus::Plugin::CapabilityProvider.new(
      plugin_name: "failing_#{family}", family:, capability:,
      provider_name:, key: nil, priority: 0
    )
    allow(Syrus::PluginRegistry).to receive(:capability_providers).and_call_original
    allow(Syrus::PluginRegistry).to receive(:capability_providers)
      .with(family, capability).and_return([ provider ])
  end

  def failing_surface_provider(capability, message) = failing_family_provider(:surface, capability, message)

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
    failing_family_provider(:toolkit, :permissions, "permission failed")
    allow(Rails.logger).to receive(:warn)

    expect(Permissions::AuthorizationAdapters.resolve("plugin.action")).to be_nil
    expect_failure(:toolkit, :permissions)
  end

  it "omits failing workflow MCP tool discovery" do
    failing_family_provider(:toolkit, :workflow_tools, "tools unavailable")
    allow(McpToolRegistry).to receive(:summaries).and_return([])

    expect(McpToolUsageRecorder.workflow_tool_names).to eq([])
    expect_failure(:toolkit, :workflow_tools)
  end

  it "omits failing MCP run-context contributions" do
    failing_family_provider(:toolkit, :run_context, "context failed")

    attributes = McpToolContext.send(:run_context_attributes, double, AgentRole::WORKFLOW_IMPLEMENT)

    expect(attributes).to eq({})
    expect_failure(:toolkit, :run_context)
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

  it "omits a failing chat prompt injector" do
    provider = Class.new do
      def self.chat_prompt_section(**) = raise("prompt failed")
    end
    providers_for(:chat_prompt_injector, [ provider ])

    prompt = Prompts::ChatSystem.new(repository: nil)

    expect(prompt.send(:plugin_guidance)).to eq("")
    expect_failure(:chat_prompt_injector, :chat_prompt_section)
  end

  it "omits a failing admin page provider" do
    failing_surface_provider(:admin_pages, "admin pages failed")

    expect(Admin::PluginPagesPayload.new.as_json).to eq(pages: [])
    expect_failure(:surface, :admin_pages)
  end

  it "omits a failing sidebar page provider" do
    failing_surface_provider(:sidebar_pages, "sidebar pages failed")

    expect(App::SidebarPagesPayload.new.as_json).to eq(pages: [])
    expect_failure(:surface, :sidebar_pages)
  end

  it "omits a failing UI slot provider" do
    failing_surface_provider(:ui_slots, "UI slots failed")

    expect(App::UiSlotsPayload.panels_for(slot: "repository.detail")).to eq([])
    expect_failure(:surface, :ui_slots)
  end

  it "falls back to the provider key when presentation lookup fails" do
    provider = Class.new do
      def self.provider_key = raise("presentation failed")
    end
    providers_for(:agent_provider, [ provider ])

    expect(App::Presentation.agent_provider_label("custom_agent")).to eq("Custom Agent")
    expect_failure(:agent_provider, :provider_key)
  end

  it "omits a failing repository page-tab provider" do
    failing_surface_provider(:repo_page_tabs, "repository tabs failed")

    tabs = Repositories::PluginRepoTabsPayload.plugin_tabs_for(repository: double, user: double)

    expect(tabs).to eq([])
    expect_failure(:surface, :repo_page_tabs)
  end

  it "omits a failing workspace-tab provider" do
    failing_surface_provider(:workspace_tabs, "workspace tabs failed")

    expect(WorkspaceTabsPayload.new(double).as_json).to eq([])
    expect_failure(:surface, :workspace_tabs)
  end

  it "omits a failing chat job-status extension" do
    provider = Class.new do
      def self.payload(**) = raise("job status failed")
    end
    providers_for(:chat_job_status_extension, [ provider ])
    relation = double
    allow(relation).to receive(:includes).and_return(relation)
    allow(relation).to receive(:to_a).and_return([])
    allow(ChatAssociatedJobs).to receive(:scope).and_return(relation)

    payload = ChatJobStatusQuery.new(double).send(:extension_payload)

    expect(payload).to eq({})
    expect_failure(:chat_job_status_extension, :payload)
  end

  [
    Api::V1::App::InputSourcesController,
    Api::V1::App::RepositoriesController
  ].each do |controller_class|
    it "omits a failing input-source schema in #{controller_class.name}" do
      provider = Class.new do
        def config_schema = raise("schema failed")
      end

      expect(controller_class.new.send(:input_source_schema, provider)).to eq([])
      expect_failure(:input_source, :config_schema)
    end
  end
end
