require "rails_helper"

# Consequence-free agent essentials still go through the permission system --
# they are evaluated and audited -- but no deny rule, preset, lease, generic
# fallback or authorization request may block them. `default: allow` is not
# enough: an explicit deny overrides any default.
RSpec.describe "essential operations" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat_session) { ChatSession.create!(user:, repository:) }
  let(:server_context) { { chat_session: } }

  def deny_rule!(descriptor, layer: "instance", operation: descriptor.operation, delegable: true, selector: "eligible_roles")
    PermissionRule.create!(
      owner_user: user, created_by_user: user, updated_by_user: user, subject_selector_type: selector,
      subject_role_keys: descriptor.requestable_roles, capability: descriptor.capability, operation:,
      resource_type: descriptor.resource_scope.type.to_s, resource_scope: {}, constraints: {}, policy: "deny",
      policy_layer: layer, source: "operator", provenance: {}, delegable:
    )
  end

  def requests = ChatPendingAction.where(request_kind: "authorization_request")

  def chat_entry(name) = McpToolRegistry.entries(surface: :chat).find { |entry| entry.tool_name == name }
  def workflow_entry(name) = McpToolRegistry.entries(surface: :workflow).find { |entry| entry.tool_name == name }
  def coworker_entry(name) = McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool_name == name }

  def memory_descriptor(name)
    AgentMemory::PermissionProvider.capability_descriptor(AgentMemory::PermissionProvider::OPERATIONS.fetch(name))
  end

  def plugin_tool(name, descriptor)
    Class.new.tap do |klass|
      klass.define_singleton_method(:tool_name) { name }
      klass.define_singleton_method(:capability_descriptor) { descriptor }
    end
  end

  describe Permissions::PolicyEvaluator do
    let(:descriptor) { chat_entry("list_jobs").descriptor }

    it "allows an essential operation over every deny rule and reports each one as overridden" do
      rules = [
        Permissions::PolicyRule.new(id: "instance-deny", layer: :instance, policy: :deny, source: "operator",
          capability: descriptor.capability, operation: descriptor.operation, delegable: false),
        Permissions::PolicyRule.new(id: "family-deny", layer: :role, policy: :deny, source: "preset",
          capability: descriptor.capability)
      ]

      decision = described_class.new(descriptor:, role: AgentRole::CHAT_PLANNER, resource_scope: {}, rules:).call

      expect(decision).to be_allow
      expect(decision.decisive_rule).to be_nil
      expect(decision.chain.map { |item| [ item.rule&.id, item.status, item.detail ] }).to include(
        [ "instance-deny", :overridden, :essential_operation ],
        [ "family-deny", :overridden, :essential_operation ],
        [ nil, :decisive_default, :essential ]
      )
    end

    it "still denies the deniable operation next to it" do
      gated = chat_entry("send_chat_message").descriptor
      rule = Permissions::PolicyRule.new(id: "deny", layer: :instance, policy: :deny, source: "operator",
        capability: gated.capability, operation: gated.operation)

      expect(described_class.new(descriptor: gated, role: AgentRole::CHAT_PLANNER, resource_scope: {}, rules: [ rule ]).call).to be_deny
    end
  end

  describe Permissions::LeaseAuthorizer do
    it "neither consults nor consumes a lease for an essential operation" do
      descriptor = chat_entry("list_jobs").descriptor
      allow(PermissionLease).to receive(:for_invocation).and_call_original

      result = described_class.call(descriptor:, owner: user, role: AgentRole::CHAT_PLANNER, resource_scope: {})

      expect(result.decision).to be_allow
      expect(result.lease).to be_nil
      expect(PermissionLease).not_to have_received(:for_invocation)
    end
  end

  describe "the chat gate" do
    def gate(tool, arguments = {})
      Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
        Mcp::Tools::AuthorizationSupport.pending_actor_approval(tool, server_context, arguments)
      end
    end

    it "lets a core essential tool run despite a deny rule, without creating a request" do
      entry = chat_entry("list_jobs")
      deny_rule!(entry.descriptor)

      expect { expect(gate(entry.tool)).to be_nil }.not_to change { requests.count }
    end

    it "creates a self-owned wakeup directly and returns its durable receipt" do
      entry = chat_entry("schedule_wakeup")
      deny_rule!(entry.descriptor)
      request_count = requests.count

      response = nil
      expect {
        response = entry.tool.call(
          prompt: "Recheck release readiness.", delay_minutes: 60,
          server_context:
        )
      }.to change(ChatWakeup, :count).by(1)
      expect(requests.count).to eq(request_count)

      wakeup = ChatWakeup.sole
      payload = JSON.parse(response.content.first[:text])
      expect(payload).to include(
        "wakeup_id" => wakeup.id,
        "chat_id" => chat_session.id,
        "owner_user_id" => user.id,
        "fire_at" => wakeup.fire_at.utc.iso8601,
        "state" => "pending"
      )
      expect(wakeup).to have_attributes(chat_session:, user:, prompt: "Recheck release readiness.")
    end

    it "audits the essential invocation through the permission system" do
      entry = chat_entry("rename_chat")
      allow(Permissions::DecisionAudit).to receive(:record)

      gate(entry.tool, { title: "Renamed" })

      expect(Permissions::DecisionAudit).to have_received(:record).with(hash_including(
        decision: having_attributes(policy: :allow, invocation: having_attributes(operation: entry.descriptor.operation))
      ))
    end

    it "lets a user's private write_memory run despite a stale deny rule, without consulting leases" do
      descriptor = memory_descriptor("write_memory")
      deny_rule!(descriptor)
      allow(PermissionLease).to receive(:for_invocation).and_call_original

      expect { expect(gate(plugin_tool("write_memory", descriptor), { content: "Prefers rebases", kind: "preference" })).to be_nil }
        .not_to change { requests.count }
      expect(PermissionLease).not_to have_received(:for_invocation)
    end

    it "keeps publish_memory and delete_memory gated" do
      %w[publish_memory delete_memory].each do |name|
        descriptor = memory_descriptor(name)
        expect(descriptor).not_to be_essential
        expect(descriptor.barrier_effects).not_to be_empty, name

        expect { gate(plugin_tool(name, descriptor), { id: 1 }) }.to change { requests.count }.by(1)
      end
    end
  end

  describe "the coworker gate" do
    it "lets an essential coworker tool run despite a deny rule, without a pending action" do
      coworker = Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
      context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user:, repository:,
        chat_session:, agent_actor: coworker)
      allow(McpToolContext).to receive(:from_server_context).and_return(context)
      entry = coworker_entry("ask_user_question")
      deny_rule!(entry.descriptor)
      allow(Permissions::DecisionAudit).to receive(:record)

      result = Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
        Mcp::Tools::AuthorizationSupport.pending_coworker_approval(entry.tool, server_context, { question: "Which?" })
      end

      expect(result).to be_nil
      expect(ChatPendingAction.count).to eq(0)
      expect(Permissions::DecisionAudit).to have_received(:record)
        .with(hash_including(decision: having_attributes(policy: :allow)))
    end

    # Coworkers have their own rules, separate from chat and from each
    # other, but the same essentials.
    it "shares the chat essentials, including research reads and plugin essentials" do
      %w[ask_user_question rename_chat list_jobs search_jobs read_job propose_job schedule_wakeup list_wakeups cancel_wakeup].each do |name|
        expect(coworker_entry(name).descriptor).to be_essential, name
        expect(coworker_entry(name).ungated).to be(true), name
      end
      expect(coworker_entry("read_chat_messages").descriptor).not_to be_essential

      coworker_memory = Permissions::CapabilityDescriptorAdapter.for_coworker_parity(memory_descriptor("write_memory"))
      expect(coworker_memory).to be_essential
      expect(Permissions::CapabilityDescriptorAdapter.for_coworker_parity(memory_descriptor("delete_memory"))).not_to be_essential
    end
  end

  describe "scheduled runs" do
    let(:job) { Factories.job_record(user:, repository:, kind: "cron", scheduled_task_id: 41, issue_number: nil) }
    let(:run) { Factories.run(job:, user:) }
    let(:context) { McpToolContext.from_run(run) }

    it "never queues or skips essential workflow output, even under a deny rule" do
      entry = workflow_entry("submit_summary")
      deny_rule!(entry.descriptor)

      expect { expect(Permissions::ScheduledAuthorization.route(tool: entry.tool, context:, arguments: { summary: "x" })).to be_nil }
        .not_to change { requests.count }
    end

    it "never blocks a plugin-contributed essential (write_memory) on a scheduled run" do
      descriptor = memory_descriptor("write_memory")
      deny_rule!(descriptor)

      result = Permissions::ScheduledAuthorization.route(tool: plugin_tool("write_memory", descriptor), context:,
        arguments: { content: "x", kind: "preference" })
      expect(result).to be_nil
    end

    it "still gates a non-essential tool on the same run" do
      descriptor = memory_descriptor("delete_memory")

      result = Permissions::ScheduledAuthorization.route(tool: plugin_tool("delete_memory", descriptor), context:, arguments: { id: 3 })
      expect(result).to be_created
    end
  end

  describe "breadth ceilings" do
    let(:raw_sql) do
      Permissions::CapabilityDescriptor.new(
        capability: "example.sql@v1", operation: "example.sql/execute@v1", effects: %i[external_write destructive],
        risk: :critical, requestable_roles: [ AgentRole::CHAT_PLANNER ], defaults: { AgentRole::CHAT_PLANNER => :ask },
        maximum_autonomy: :permanent, authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        breadth_ceilings: { family: :invocation, tool: :invocation, resource: :permanent },
        resource_scope: { type: :none }, classifier: ->(_arguments) { {} },
        fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments },
        constraint_fields: { "database" => :string }
      )
    end

    def allow_rule(id, source: "operator", **attributes)
      Permissions::PolicyRule.new(id:, layer: :agent, policy: :allow, source:, capability: raw_sql.capability, **attributes)
    end

    def decide(rules, arguments = { "database" => "staging" })
      Permissions::PolicyEvaluator.new(descriptor: raw_sql, role: AgentRole::CHAT_PLANNER, resource_scope: {}, rules:, arguments:).call
    end

    it "lets a permanent allow for one named database through" do
      expect(decide([ allow_rule("staging", operation: raw_sql.operation, constraints: { "database" => "staging" }) ])).to be_allow
    end

    it "does not let a permanent family- or tool-wide allow grant raw SQL" do
      family = decide([ allow_rule("family") ])
      tool = decide([ allow_rule("tool", operation: raw_sql.operation) ])

      [ family, tool ].each do |decision|
        expect(decision).to be_ask
        expect(decision.chain.map(&:detail)).to include(:exceeds_breadth_ceiling)
      end
    end

    it "still honours an operator's permission profile, which is a central declaration" do
      expect(decide([ allow_rule("profile", source: "permission_profile:full_access@v1") ])).to be_allow
    end
  end

  describe "rule authoring" do
    it "refuses rules that target an essential operation for a role where it is essential" do
      descriptor = chat_entry("list_jobs").descriptor
      draft = Permissions::RuleDraft.new(user:, attributes: {
        "policy" => "deny", "duration" => "permanent", "subject_selector_type" => "interactive_chat",
        "capability" => descriptor.capability, "operation" => descriptor.operation
      })

      expect(draft.preview.errors.pluck(:code)).to include("essential_operation")
    end

    it "treats an essential the same for chats and coworkers" do
      descriptor = chat_entry("list_jobs").descriptor

      expect(Permissions::Catalog.essential_for?(descriptor.operation, role: AgentRole::CHAT_PLANNER)).to be(true)
      expect(Permissions::Catalog.essential_for?(descriptor.operation, role: AgentRole::COWORKER_CHAT)).to be(true)
      expect(Permissions::Catalog.essential_for?(memory_descriptor("write_memory").operation, role: AgentRole::COWORKER_CHAT)).to be(true)
    end
  end
end
