require "rails_helper"

RSpec.describe "coworker permission requests and self-surrender" do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:other_coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Nico", handle: "nico", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:other_chat) { ChatSession.create!(user: owner, repository: repository, title: "Nico") }
  let(:capability) { "database.read@v1" }
  let(:operation) { "database.read/query@v1" }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability:, operation:, effects: [ :confidential_read ], risk: :medium,
      requestable_roles: [ AgentRole::COWORKER_CHAT ], defaults: { AgentRole::COWORKER_CHAT => :ask },
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session job permanent],
      resource_scope: { type: :none }, classifier: ->(_arguments) { {} },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments },
      constraint_fields: { "table" => :string }
    )
  end
  let(:session_only_descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "files.write@v1", operation: "files.write/save@v1", effects: [ :internal_write ], risk: :medium,
      requestable_roles: [ AgentRole::COWORKER_CHAT ], defaults: { AgentRole::COWORKER_CHAT => :ask },
      maximum_autonomy: :chat_session, authority_durations: %i[invocation chat_session],
      resource_scope: { type: :none }, classifier: ->(_arguments) { {} },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_chat, role: "main")
    chat_coworker = coworker
    chat.define_singleton_method(:coworker) { chat_coworker }
    other_chat_coworker = other_coworker
    other_chat.define_singleton_method(:coworker) { other_chat_coworker }
    catalog = [ descriptor, session_only_descriptor ]
    allow(Permissions::Catalog).to receive(:find!) do |capability:, operation: nil|
      catalog.find { |candidate| candidate.capability == capability.to_s && (operation.blank? || candidate.operation == operation.to_s) } ||
        raise(Permissions::Catalog::UnknownCapability, "unknown permission capability or operation")
    end
  end

  def server_context(session = chat, actor = coworker) = { chat_session: session, agent_actor: actor }
  def body(response) = JSON.parse(response.content.first[:text], symbolize_names: true)

  def request_permission(session: chat, actor: coworker, **arguments)
    Mcp::Tools::RequestPermissionTool.call(
      server_context: server_context(session, actor),
      **{ capability:, operation:, purpose: "Answer a customer question" }.merge(arguments)
    )
  end

  def audit_events(name) = AdminAction.where(action: name)

  def approve(request, duration)
    item = request.authorization_items.sole
    option = Permissions::SmartDecision.new(request:, item:, user: owner).option
    expect(option).to include(duration:)
    Permissions::CoworkerAuthorizationDecision.new(request:, item:, user: owner)
      .call(decision: "approved", smart: { duration:, digest: option.fetch(:digest) })
  end

  describe "request_permission" do
    it "creates an owner-facing request for the calling coworker and grants nothing" do
      response = request_permission(duration: "chat_session")

      expect(response.error?).to be(false)
      payload = body(response)
      request = ChatPendingAction.find(payload.fetch(:authorization_request_id))
      expect(payload).to include(status: "created", grants_authority: false, requested_duration: "chat_session")
      expect(request).to have_attributes(
        request_kind: "authorization_request", action: "coworker_permission_request", state: "pending",
        subject: coworker, user: owner, chat_session: chat, repository: repository, purpose: "Answer a customer question"
      )
      expect(request.authorization_items.sole).to have_attributes(
        capability: "database.read", operation: "database.read/query", state: "pending",
        requested_durations: payload.fetch(:offered_durations)
      )
      expect(PermissionLease.count).to eq(0)
      expect(PermissionRule.count).to eq(0)
      expect(audit_events("coworker_permission_requested").sole.params).to include(
        "coworker_id" => coworker.id, "authorization_request_id" => request.id
      )
    end

    it "shows the request in the approval inbox next to blocked tool calls" do
      request = ChatPendingAction.find(body(request_permission).fetch(:authorization_request_id))

      expect(Coworkers::PendingApprovals.new(owner:, coworker:).relation).to include(request)
      expect(Coworkers::PendingApprovals.new(owner:, coworker: other_coworker).relation).not_to include(request)
    end

    it "offers only durations the descriptor and the draft preview accept" do
      payload = body(request_permission(capability: "files.write@v1", operation: "files.write/save@v1"))

      expect(payload.fetch(:offered_durations)).to eq([ "chat_session" ])
      response = request_permission(capability: "files.write@v1", operation: "files.write/save@v1", duration: "permanent")
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("duration_not_offered")
    end

    it "does not offer permanent authority for a constrained request" do
      payload = body(request_permission(constraints: { "table" => "orders" }))

      expect(payload.fetch(:offered_durations)).to eq([ "chat_session" ])
    end

    it "caps the owner's approval at the duration the coworker asked for" do
      request = ChatPendingAction.find(body(request_permission(duration: "chat_session")).fetch(:authorization_request_id))

      option = Permissions::SmartDecision.new(request:, item: request.authorization_items.sole, user: owner).option

      expect(option).to include(duration: "chat_session")
    end

    it "refuses permission administration, unknown capabilities and missing purposes" do
      expect(request_permission(capability: "syrus.permissions@v1", operation: "syrus.permissions/grant@v1").error?).to be(true)
      expect(request_permission(capability: "nope@v1", operation: "nope/op@v1").content.first[:text]).to include("unknown_capability")
      expect(request_permission(purpose: " ").content.first[:text]).to include("purpose_required")
      expect(ChatPendingAction.where(action: "coworker_permission_request")).to be_empty
    end

    it "returns the existing request instead of flooding the owner with equivalent cards" do
      first = body(request_permission)
      second = body(request_permission(purpose: "Same thing, again"))

      expect(second).to include(status: "deduplicated", authorization_request_id: first.fetch(:authorization_request_id))
      expect(ChatPendingAction.where(action: "coworker_permission_request").count).to eq(1)
      expect(audit_events("coworker_permission_request_deduplicated").count).to eq(1)
    end

    it "limits how many requests can wait for the owner at once" do
      stub_const("Permissions::CoworkerPermissionRequest::MAX_PENDING", 1)
      request_permission

      response = request_permission(capability: "files.write@v1", operation: "files.write/save@v1")

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("too_many_pending")
      expect(ChatPendingAction.where(action: "coworker_permission_request").count).to eq(1)
      expect(audit_events("coworker_permission_request_rate_limited").count).to eq(1)
    end

    it "limits the hourly request rate even after earlier requests were decided" do
      stub_const("Permissions::CoworkerPermissionRequest::MAX_PER_HOUR", 1)
      first = ChatPendingAction.find(body(request_permission).fetch(:authorization_request_id))
      first.update!(state: "cancelled")

      response = request_permission(capability: "files.write@v1", operation: "files.write/save@v1")

      expect(response.content.first[:text]).to include("rate_limited")
    end

    it "does not re-ask right after the owner denied an equivalent request" do
      request = ChatPendingAction.find(body(request_permission).fetch(:authorization_request_id))
      Permissions::CoworkerAuthorizationDecision.new(request:, item: request.authorization_items.sole, user: owner)
        .call(decision: "denied")

      expect(request.reload).to have_attributes(state: "rejected")
      expect(audit_events("coworker_permission_request_denied").sole.params).to include("authorization_request_id" => request.id)
      response = request_permission
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("recently_denied")
    end

    it "reports an operation the coworker already holds without opening a request" do
      request = ChatPendingAction.find(body(request_permission).fetch(:authorization_request_id))
      approve(request, "chat_session")

      payload = body(request_permission)

      expect(payload).to include(status: "already_authorized", authorization_request_id: nil)
    end

    it "applies the approval as a lease for exactly the requesting coworker" do
      request = ChatPendingAction.find(body(request_permission(duration: "chat_session")).fetch(:authorization_request_id))

      result = approve(request, "chat_session")

      expect(result.execution_enqueued).to be(false)
      expect(request.reload).to have_attributes(state: "confirmed")
      lease = PermissionLease.sole
      expect(lease).to have_attributes(
        owner_user: owner, subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
        capability:, duration_kind: "chat_session", chat_session: chat
      )
      expect(request.authorization_items.sole.resulting_authority).to eq(lease)
      expect(audit_events("coworker_permission_granted").sole.params).to include("coworker_id" => coworker.id)
    end

    it "refuses a bare approval and the generic approval path for a permission request" do
      request = ChatPendingAction.find(body(request_permission).fetch(:authorization_request_id))

      expect {
        Permissions::CoworkerAuthorizationDecision.new(request:, item: request.authorization_items.sole, user: owner)
          .call(decision: "approved")
      }.to raise_error(ArgumentError)
      expect(request.reload).to be_pending
      expect { request.confirm!(user: owner) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(PermissionLease.count).to eq(0)
    end

    it "is not available to a non-coworker role" do
      context = { chat_session: ChatSession.create!(user: owner, repository:) }
      response = Mcp::Tools::RequestPermissionTool.call(server_context: context, capability:, operation:, purpose: "x")

      expect(response.error?).to be(true)
      expect(ChatPendingAction.where(action: "coworker_permission_request")).to be_empty
    end
  end

  describe "surrender_permission_lease" do
    def lease_for(subject, duration: "chat_session", session: chat)
      Permissions::Management.new(owner).lease!({
        "role" => AgentRole::COWORKER_CHAT, "subject_selector_type" => "agent", "subject_selector_id" => subject.id.to_s,
        "subject_repository_id" => repository.id, "capability" => capability, "operation" => operation,
        "duration" => duration, "chat_session_id" => session.id
      }, actor: owner)
    end

    def surrender(lease_id, actor: coworker, session: chat)
      Mcp::Tools::SurrenderPermissionLeaseTool.call(server_context: server_context(session, actor), permission_lease_id: lease_id)
    end

    it "revokes the coworker's own active lease immediately without owner confirmation" do
      lease = lease_for(coworker)

      response = surrender(lease.id)

      expect(response.error?).to be(false)
      expect(lease.reload.revoked_at).to be_present
      expect(ChatPendingAction.where(action: "revoke_permission_lease")).to be_empty
      expect(audit_events("coworker_permission_lease_surrendered").sole.params).to include(
        "coworker_id" => coworker.id, "permission_lease_id" => lease.id
      )
      expect(Permissions::Management.new(owner).authorize(
        descriptor:, role: AgentRole::COWORKER_CHAT, resource_scope: {}, arguments: {},
        context: { role: AgentRole::COWORKER_CHAT, subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
                   subject_repository_id: repository.id, chat_session_id: chat.id, agent_id: coworker.id }
      )).not_to be_authorized
    end

    it "cannot surrender another coworker's lease" do
      lease = lease_for(other_coworker, session: other_chat)

      response = surrender(lease.id)

      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("lease_not_found")
      expect(lease.reload.revoked_at).to be_nil
      expect(audit_events("coworker_permission_lease_surrendered")).to be_empty
    end

    it "cannot surrender a role-wide lease or another owner's lease" do
      role_lease = Permissions::Management.new(owner).lease!({
        "role" => AgentRole::COWORKER_CHAT, "subject_selector_type" => "workflow_role", "subject_selector_id" => AgentRole::COWORKER_CHAT,
        "capability" => capability, "operation" => operation, "duration" => "chat_session", "chat_session_id" => chat.id
      }, actor: owner) rescue nil
      foreign = Factories.user
      foreign_lease = PermissionLease.create!(
        owner_user: foreign, issued_by_user: foreign, subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
        capability: "database.read", operation: "database.read/query", resource_type: "none", duration_kind: "job",
        job: Factories.job(user: foreign), resource_scope: {}, constraints: {}, effects: []
      ) rescue nil

      [ role_lease, foreign_lease ].compact.each do |lease|
        expect(surrender(lease.id).error?).to be(true)
        expect(lease.reload.revoked_at).to be_nil
      end
    end

    it "is not available to a chat that is not a coworker" do
      lease = lease_for(coworker)
      response = Mcp::Tools::SurrenderPermissionLeaseTool.call(
        server_context: { chat_session: ChatSession.create!(user: owner, repository:) }, permission_lease_id: lease.id
      )

      expect(response.error?).to be(true)
      expect(lease.reload.revoked_at).to be_nil
    end
  end

  describe "request_permission_revocation" do
    def rule_for(subject, selector: "agent")
      Permissions::Management.new(owner).grant!({
        "role" => AgentRole::COWORKER_CHAT, "subject_selector_type" => selector,
        "subject_selector_id" => (subject.id.to_s if selector == "agent"), "subject_repository_id" => nil,
        "capability" => capability, "operation" => operation, "resource_scope" => {}
      }, actor: owner)
    end

    def request_revocation(rule_id, session: chat, actor: coworker)
      Mcp::Tools::RequestPermissionRevocationTool.call(
        server_context: server_context(session, actor), permission_rule_id: rule_id, rationale: "No longer needed"
      )
    end

    it "creates an owner-confirmed request and leaves the rule untouched until confirmation" do
      rule = rule_for(coworker)

      payload = body(request_revocation(rule.id))
      pending = ChatPendingAction.find(payload.fetch(:pending_action_id))

      expect(payload).to include(status: "created", revoked: false)
      expect(pending).to have_attributes(action: "coworker_permission_revocation", state: "pending", subject: coworker, user: owner)
      expect(rule.reload.revoked_at).to be_nil
      expect(audit_events("coworker_permission_revocation_requested").sole.params).to include("permission_rule_id" => rule.id)

      pending.confirm!(user: owner)

      expect(rule.reload.revoked_at).to be_present
      expect(rule.audit_events.pluck(:event_type)).to include("revoked")
      expect(audit_events("coworker_permission_revoked").sole.params).to include("permission_rule_id" => rule.id)
    end

    it "deduplicates equivalent revocation requests" do
      rule = rule_for(coworker)
      first = body(request_revocation(rule.id))
      second = body(request_revocation(rule.id))

      expect(second).to include(status: "deduplicated", pending_action_id: first.fetch(:pending_action_id))
      expect(ChatPendingAction.where(action: "coworker_permission_revocation").count).to eq(1)
    end

    it "cannot target a rule that applies to another coworker or to a whole role" do
      others_rule = rule_for(other_coworker)
      role_rule = rule_for(nil, selector: "interactive_chat") rescue nil

      [ others_rule, role_rule ].compact.each do |rule|
        response = request_revocation(rule.id)
        expect(response.error?).to be(true)
        expect(response.content.first[:text]).to include("rule_not_found")
      end
      expect(ChatPendingAction.where(action: "coworker_permission_revocation")).to be_empty
    end

    it "re-checks the subject when the owner confirms" do
      rule = rule_for(coworker)
      pending = ChatPendingAction.find(body(request_revocation(rule.id)).fetch(:pending_action_id))
      rule.update_columns(subject_selector_id: other_coworker.id.to_s)

      expect { pending.confirm!(user: owner) }.to raise_error(ArgumentError, /does not apply/)
      expect(rule.reload.revoked_at).to be_nil
      expect(audit_events("coworker_permission_revoked")).to be_empty
    end
  end

  describe "hard boundaries" do
    it "keeps permission-store administration off the coworker surface" do
      names = McpToolRegistry.entries(surface: :coworker).map(&:tool_name)

      expect(names).to include("request_permission", "surrender_permission_lease", "request_permission_revocation")
      expect(names & %w[grant_permission deny_permission revoke_permission create_permission_lease
        revoke_permission_lease apply_permission_preset cancel_authorization_request list_permissions explain_permission]).to be_empty
    end

    it "gives the new tools no way to name another subject" do
      properties = [ Mcp::Tools::RequestPermissionTool, Mcp::Tools::SurrenderPermissionLeaseTool, Mcp::Tools::RequestPermissionRevocationTool ]
        .flat_map { |tool| tool.input_schema.to_h[:properties].keys.map(&:to_s) }

      expect(properties).not_to include("subject_selector_type", "subject_selector_id", "coworker_id", "agent_id", "role", "owner_user_id")
    end

    it "does not carry a lease from one coworker to another, whatever they ask each other" do
      Permissions::Management.new(owner).lease!({
        "role" => AgentRole::COWORKER_CHAT, "subject_selector_type" => "agent", "subject_selector_id" => coworker.id.to_s,
        "subject_repository_id" => repository.id, "capability" => capability, "operation" => operation,
        "duration" => "chat_session", "chat_session_id" => chat.id
      }, actor: owner)

      evaluate = lambda do |subject, session|
        Permissions::Management.new(owner).authorize(
          descriptor:, role: AgentRole::COWORKER_CHAT, resource_scope: {}, arguments: {},
          context: { role: AgentRole::COWORKER_CHAT, subject_selector_type: "agent", subject_selector_id: subject.id.to_s,
                     subject_repository_id: repository.id, chat_session_id: session.id, agent_id: subject.id }
        ).authorized?
      end

      expect(evaluate.call(coworker, chat)).to be(true)
      # Nico acting on Maya's behalf (or in Maya's chat) is still evaluated as Nico.
      expect(evaluate.call(other_coworker, other_chat)).to be(false)
      expect(evaluate.call(other_coworker, chat)).to be(false)
    end

    it "files a coworker's request under that coworker even when another coworker's chat is involved" do
      payload = body(request_permission(session: other_chat, actor: other_coworker))

      expect(ChatPendingAction.find(payload.fetch(:authorization_request_id)).subject).to eq(other_coworker)
      expect(ChatPendingAction.where(subject: coworker)).to be_empty
    end
  end
end
