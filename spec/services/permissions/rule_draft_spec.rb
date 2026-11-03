require "rails_helper"

RSpec.describe Permissions::RuleDraft do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat_role) { PermissionRule::SUBJECT_SELECTORS.fetch("interactive_chat").fetch(:role) }
  let(:maximum_autonomy) { :permanent }
  let(:constraint_fields) { { "branch" => :string, "dry_run" => :boolean } }
  let(:schema) do
    Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: lambda { |scope, context:|
        scope = scope.to_h.stringify_keys
        { repository_id: Integer(scope.fetch("repository_id")) }
      },
      compare: ->(left, right, context:) { left == right ? :equal : :disjoint },
      label: ->(scope, context:) { "repository ##{scope.fetch('repository_id')}" }
    )
  end
  let(:descriptor) { build_descriptor }

  def build_descriptor(**overrides)
    Permissions::CapabilityDescriptor.new(**{
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1",
      effects: %i[internal_write], risk: :medium,
      requestable_roles: [ chat_role, "implementer", AgentRole::WORKFLOW_IMPLEMENT ], defaults: { chat_role => :ask, "implementer" => :ask, AgentRole::WORKFLOW_IMPLEMENT => :ask },
      maximum_autonomy:, authority_durations: %i[invocation chat_session job permanent],
      resource_scope: schema, constraint_fields:,
      classifier: ->(_arguments) { { operation: "syrus.deploys/run@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    }.merge(overrides))
  end

  before { allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] } }

  def draft(overrides = {}, options = {})
    described_class.new(user:, attributes: {
      "policy" => "allow", "duration" => "permanent", "subject_selector_type" => "interactive_chat",
      "capability" => "syrus.deploys@v1", "operation" => "syrus.deploys/run@v1",
      "resource_scope" => { "repository_id" => repository.id }
    }.merge(overrides), **options)
  end

  def error_codes(preview) = preview.errors.pluck(:code)

  it "previews the exact subject, operation, normalized scope and duration with a human summary" do
    preview = draft.preview

    expect(preview).to be_valid
    expect(preview.draft).to include(
      policy: "allow", duration: "permanent", role: chat_role, capability: "syrus.deploys@v1",
      operation: "syrus.deploys/run@v1", resource_scope: { "repository_id" => repository.id },
      resource_scope_label: "repository ##{repository.id}"
    )
    expect(preview.summary[:allows].first).to include("syrus.deploys/run@v1", "repository ##{repository.id}", "until revoked")
    expect(preview.summary[:excludes]).to include(a_string_matching(/every other operation/))
    expect(preview.digest).to be_present
  end

  it "applies a permanent draft through the shared grant path as an audited rule" do
    preview = draft.preview

    rule = draft.apply!(digest: preview.digest, actor: user)

    expect(rule).to be_a(PermissionRule).and be_persisted
    expect(rule).to have_attributes(policy: "allow", subject_selector_type: "interactive_chat",
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", resource_scope: { "repository_id" => repository.id })
    expect(rule.audit_events.pluck(:event_type)).to eq([ "created" ])
  end

  it "applies chat-session authority as a lease with descriptor-bounded constraints" do
    chat_session = ChatSession.create!(user:, title: "Deploys")
    attrs = { "duration" => "chat_session", "chat_session_id" => chat_session.id, "constraints" => { "branch" => "main" } }
    preview = draft(attrs).preview
    expect(preview).to be_valid
    expect(preview.summary[:allows].last).to include("branch = main")

    lease = draft(attrs).apply!(digest: preview.digest, actor: user)

    expect(lease).to be_a(PermissionLease)
    expect(lease).to have_attributes(duration_kind: "chat_session", chat_session:, constraints: { "branch" => "main" })
  end

  describe "validation against the descriptor and policy evaluator" do
    it "rejects unknown capabilities, missing operations and ineligible roles" do
      expect(error_codes(draft("capability" => "nope@v1").preview)).to eq([ "unknown_capability" ])
      expect(error_codes(draft("operation" => nil).preview)).to eq([ "operation_required" ])
      expect(error_codes(draft("subject_selector_type" => "coding_chat").preview)).to include("role_not_eligible")
      expect(error_codes(draft("subject_selector_type" => "eligible_roles").preview)).to include("unsupported_subject")
    end

    it "requires exact ids for workflow roles and forbids them for chat types" do
      expect(error_codes(draft("subject_selector_type" => "workflow_role").preview)).to include("subject_id_required")
      expect(error_codes(draft("subject_selector_id" => "x").preview)).to include("subject_id_forbidden")
      expect(draft("subject_selector_type" => "workflow_role", "subject_selector_id" => "implementer").preview).to be_valid
    end

    it "rejects unsupported scopes instead of defaulting to broader authority" do
      expect(error_codes(draft("resource_scope" => { "repository_id" => "abc" }).preview)).to eq([ "invalid_resource_scope" ])
      expect(error_codes(draft("resource_scope" => {}).preview)).to eq([ "invalid_resource_scope" ])
    end

    it "requires a lifecycle owner the user can access" do
      other = ChatSession.create!(user: Factories.user, title: "Other")
      expect(error_codes(draft("duration" => "chat_session", "chat_session_id" => other.id).preview)).to eq([ "chat_session_required" ])
      expect(error_codes(draft("duration" => "job").preview)).to eq([ "job_required" ])
    end

    it "makes ask and deny rules permanent only" do
      expect(error_codes(draft("policy" => "deny", "duration" => "job").preview)).to include("restrictive_rules_are_permanent")
      expect(draft("policy" => "deny").preview).to be_valid
    end
  end

  describe "permanent authority" do
    context "when the descriptor forbids it" do
      let(:maximum_autonomy) { :job }

      it "is rejected" do
        expect(error_codes(draft.preview)).to eq([ "permanent_forbidden" ])
        expect(Permissions::RuleDraftOptions.new(descriptor, user:).as_json)
          .to include(permanent_allowed: false, authority_durations: %w[chat_session job])
      end
    end

    context "when the descriptor does not list it" do
      let(:descriptor) { build_descriptor(authority_durations: %i[invocation chat_session], maximum_autonomy: :chat_session) }

      it "is rejected" do
        expect(error_codes(draft.preview)).to include("duration_not_offered")
      end
    end

    it "is rejected when a higher non-delegable policy ceiling asks or denies" do
      PermissionRule.create!(
        owner_user: user, created_by_user: user, updated_by_user: user, subject_selector_type: "interactive_chat",
        capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", resource_type: "repository",
        resource_scope: { "repository_id" => repository.id }, constraints: {}, policy: "ask", policy_layer: "instance",
        source: "operator", provenance: {}, subject_role_keys: [], delegable: false
      )

      preview = draft.preview

      expect(error_codes(preview)).to eq([ "exceeds_policy_ceiling" ])
      expect(Permissions::RuleDraftOptions.new(descriptor, user:).as_json[:ceilings])
        .to contain_exactly(include(layer: "instance", policy: "ask"))
    end
  end

  describe "argument constraints" do
    it "accepts only descriptor-defined, non-sensitive, correctly typed constraints on lease authority" do
      chat_session = ChatSession.create!(user:, title: "c")
      base = { "duration" => "chat_session", "chat_session_id" => chat_session.id }

      expect(error_codes(draft(base.merge("constraints" => { "force" => true })).preview)).to eq([ "constraint_not_supported" ])
      expect(error_codes(draft(base.merge("constraints" => { "dry_run" => "yes" })).preview)).to eq([ "constraint_invalid_value" ])
      expect(error_codes(draft(base.merge("constraints" => { "branch" => "Bearer abcdefghijklmnop1234" })).preview))
        .to eq([ "constraint_invalid_value" ])
    end

    it "refuses constraints on permanent rules, which the evaluator does not enforce" do
      expect(error_codes(draft("constraints" => { "branch" => "main" }).preview)).to eq([ "constraints_not_enforceable" ])
    end

    it "rejects descriptors that expose secret-like constraint fields" do
      expect { build_descriptor(constraint_fields: { "api_token" => :string }) }.to raise_error(ArgumentError, /secrets/)
      expect { build_descriptor(constraint_fields: { "branch" => :regex }) }.to raise_error(ArgumentError, /types/)
    end
  end

  describe "stale previews" do
    it "refuses a digest from an edited scope" do
      preview = draft.preview
      edited = draft("resource_scope" => { "repository_id" => repository.id + 1 })

      expect { edited.apply!(digest: preview.digest, actor: user) }.to raise_error(described_class::Stale)
      expect(PermissionRule.count).to eq(0)
    end

    it "refuses a missing or forged digest" do
      expect { draft.apply!(digest: nil, actor: user) }.to raise_error(described_class::Stale)
      expect { draft.apply!(digest: "forged", actor: user) }.to raise_error(described_class::Stale)
    end

    it "goes stale when the owner's rules change after review" do
      preview = draft.preview
      PermissionRule.create!(
        owner_user: user, created_by_user: user, updated_by_user: user, subject_selector_type: "coding_chat",
        capability: "other@v1", resource_type: "none", resource_scope: {}, constraints: {}, policy: "deny",
        policy_layer: "agent", source: "operator", provenance: {}, subject_role_keys: []
      )

      expect { draft.apply!(digest: preview.digest, actor: user) }.to raise_error(described_class::Stale)
    end

    it "goes stale when the descriptor contract is upgraded" do
      preview = draft.preview
      allow(Permissions::Catalog).to receive(:descriptors) { [ build_descriptor(maximum_autonomy: :permanent, constraint_fields: {}) ] }

      expect { draft.apply!(digest: preview.digest, actor: user) }.to raise_error(described_class::Stale)
    end

    it "is invalid, not stale, when an upgrade removes the offered duration" do
      preview = draft.preview
      allow(Permissions::Catalog).to receive(:descriptors) { [ build_descriptor(maximum_autonomy: :job) ] }

      expect { draft.apply!(digest: preview.digest, actor: user) }.to raise_error(described_class::Invalid)
    end
  end

  describe "scope boundary and redaction" do
    it "flags a scope edited beyond the original request" do
      requested = { "repository_id" => repository.id }
      broader = draft({ "resource_scope" => { "repository_id" => repository.id + 1 } }, { request_scope: requested }).preview

      expect(broader.warnings.pluck(:code)).to eq([ "scope_not_covering_request" ])
      expect(draft({}, { request_scope: requested }).preview.warnings).to be_empty
    end

    it "redacts secrets echoed in previews while keeping the scope meaningful" do
      secret_schema = Permissions::ResourceScopeSchema.new(
        type: :target,
        normalize: ->(scope, context:) { { "host" => scope.to_h.stringify_keys.fetch("host"), "api_token" => "tok-123456789" } },
        label: ->(scope, context:) { "#{scope['host']} token=#{scope['api_token']}" }
      )
      allow(Permissions::Catalog).to receive(:descriptors) { [ build_descriptor(resource_scope: secret_schema) ] }

      preview = draft("resource_scope" => { "host" => "db.example.com" }).preview

      expect(preview.draft[:resource_scope]).to include("host" => "db.example.com", "api_token" => "[redacted]")
      expect(preview.to_h.to_json).not_to include("tok-123456789")
    end
  end

  describe ".from_request_item" do
    let(:request) do
      ChatPendingAction.create!(
        request_kind: "authorization_request", user:, repository:, chat_session: ChatSession.create!(user:, title: "o"), origin: ChatSession.create!(user:, title: "o"),
        subject: user, runtime_role: chat_role, deduplication_key: "draft-request"
      )
    end
    let(:item) do
      request.authorization_items.create!(
        kind: "operation", capability: "syrus.deploys", capability_version: 1, operation: "syrus.deploys/run",
        operation_version: 1, resource_type: "repository", resource_scope: { "repository_id" => repository.id },
        normalized_arguments: {}, invocation_fingerprint: "fp", effects: [], policy_chain: [], requested_durations: [ "invocation" ]
      )
    end

    def request_for(runtime_role:, repository: self.repository, subject: user)
      ChatPendingAction.create!(
        request_kind: "authorization_request", user:, repository:, chat_session: ChatSession.create!(user:, title: "o"),
        origin: ChatSession.create!(user:, title: "o"), subject:, runtime_role:, deduplication_key: SecureRandom.hex(8)
      )
    end

    def item_for(request, arguments: {})
      request.authorization_items.create!(
        kind: "operation", capability: "syrus.deploys", capability_version: 1, operation: "syrus.deploys/run",
        operation_version: 1, resource_type: "repository", resource_scope: { "repository_id" => repository.id },
        normalized_arguments: arguments, invocation_fingerprint: SecureRandom.hex(4), effects: [],
        policy_chain: [], requested_durations: [ "invocation" ]
      )
    end

    def derived(request, **arguments)
      described_class.from_request_item(user:, request:, item: item_for(request, **arguments), duration: "chat_session")
    end

    it "refuses agent subjects that are not exact, owned coworkers" do
      other = described_class.new(user:, attributes: {
        "duration" => "chat_session", "subject_selector_type" => "agent", "subject_selector_id" => user.id,
        "subject_type" => "User", "role" => chat_role, "capability" => "syrus.deploys@v1", "operation" => "syrus.deploys/run@v1"
      })

      expect(error_codes(other.preview)).to include("unknown_subject")
    end

    it "maps chat, workflow and repository runtime roles onto canonical selectors" do
      chat = derived(request_for(runtime_role: chat_role)).preview
      expect(chat).to be_valid
      expect(chat.draft[:subject]).to include(type: "interactive_chat", id: nil)

      repo_role = derived(request_for(runtime_role: AgentRole::WORKFLOW_IMPLEMENT)).preview
      expect(repo_role).to be_valid
      expect(repo_role.draft[:subject]).to include(type: "repository_role", id: AgentRole::WORKFLOW_IMPLEMENT, repository_id: repository.id)

      workflow = derived(request_for(runtime_role: AgentRole::WORKFLOW_IMPLEMENT, repository: nil)).preview
      expect(workflow).to be_valid
      expect(workflow.draft[:subject]).to include(type: "workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT)
    end

    it "does not guess a subject for an unsupported runtime role" do
      expect(error_codes(derived(request_for(runtime_role: "mystery")).preview)).to include("unsupported_subject")
    end

    it "keeps only safe, descriptor-declared, correctly typed arguments as constraints" do
      arguments = { "branch" => "main", "dry_run" => true, "force" => true, "api_token" => "tok",
                    "extra" => "x" }
      preview = derived(request_for(runtime_role: chat_role), arguments:).preview

      expect(preview).to be_valid
      expect(preview.draft[:constraints]).to eq("branch" => "main", "dry_run" => true)

      redacted = derived(request_for(runtime_role: chat_role), arguments: { "branch" => "[redacted]", "dry_run" => "yes" }).preview
      expect(redacted.draft[:constraints]).to eq({})
    end

    it "refuses another user's request" do
      expect { described_class.from_request_item(user: Factories.user, request:, item:, duration: "job") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
