require "rails_helper"

RSpec.describe Permissions::ApprovalProviderLifecycle do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:outcome) { { outcome: :allow, rationale: "Matches the operator's request", policy_factors: [ "intent" ], confidence: 0.95, evidence: {} } }
  let(:calls) { [] }
  let(:provider) do
    seen = calls
    result = -> { outcome }
    Class.new do
      include Syrus::Plugin::ApprovalProvider
      define_singleton_method(:provider_key) { "reviewer" }
      define_singleton_method(:display_name) { "Reviewer" }
      define_singleton_method(:data_sharing) { "Sent to Reviewer Cloud." }
      define_singleton_method(:default_guidance) { "Be careful." }
      define_singleton_method(:decide) { |evidence| seen << evidence; result.call }
    end
  end
  let(:request) do
    ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job, subject: user,
      runtime_role: "implementer", deduplication_key: "agent:#{user.id}:k8s:fp", purpose: "Restart the workload")
  end
  let!(:item) do
    request.authorization_items.create!(kind: "operation", capability: "k8s.workload", operation: "restart",
      operation_version: 1, resource_type: "cluster", resource_scope: { cluster_id: 7 },
      normalized_arguments: { id: 7 }, invocation_fingerprint: "sha256:exact", effects: [ "operational" ],
      policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation job])
  end
  let!(:delegation) do
    ApprovalProviderDelegation.create!(owner_user: user, provider_key: "reviewer", capability: "k8s.workload",
      resource_type: "cluster", resource_scope: { cluster_id: 7 })
  end
  let(:transcript) { [ { role: "user", content: "Please restart it" } ] }

  def run(**options)
    described_class.call(request: request.reload, tool_name: "restart_workload", transcript:,
      providers: [ provider ], **options)
  end

  it "approves the existing item and issues exactly one invocation atomically" do
    result = run

    expect(result).to be_approved
    expect(request.reload).to be_confirmed
    expect(item.reload).to have_attributes(state: "approved", selected_duration: "invocation",
      decision_principal: delegation, resulting_authority: nil)
    expect(result.invocation).to have_attributes(invocation_fingerprint: "sha256:exact", state: "issued", authority: nil)
    expect(ChatPendingAction.where(deduplication_key: request.deduplication_key).count).to eq(1)
    expect(run).to be_skipped
    expect(AuthorizedInvocation.where(pending_action_item: item).count).to eq(1)
  end

  it "rolls everything back when issuance fails" do
    allow(AuthorizedInvocation).to receive(:issue!).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect(run).to be_escalated
    expect(item.reload).to be_pending
    expect(request.reload).to be_pending
  end

  it "rejects only the current attempt on deny and leaves resubmissions free of a cooldown" do
    allow(provider).to receive(:decide) { calls << :denied; { outcome: :deny, rationale: "Unsafe", policy_factors: [], confidence: 0.9, evidence: {} } }

    result = run

    expect(result).to be_denied
    expect(request.reload).to be_rejected
    expect(item.reload).to be_denied
    expect(PermissionRule.count).to eq(0)
    expect(AuthorizedInvocation.count).to eq(0)

    routed = Permissions::AuthorizationRequestRouter.route!(user:, repository:, origin: job, subject: user,
      runtime_role: "implementer", deduplication_key: request.deduplication_key, purpose: "Restart again",
      capability: "k8s.workload", operation: "restart",
      item_attributes: { kind: "operation", operation_version: 1, resource_type: "cluster",
        invocation_fingerprint: "sha256:exact", resource_scope: {}, normalized_arguments: {}, effects: [],
        policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation] })
    expect(routed).not_to be_suppressed
  end

  it "escalates low confidence without duplicating the request and does not re-ask for unchanged evidence" do
    low = { outcome: :allow, rationale: "Maybe", policy_factors: [], confidence: 0.3, evidence: {} }
    allow(provider).to receive(:decide) { calls << :asked; low }

    expect(run).to be_escalated
    expect(run).to be_unchanged
    expect(calls.size).to eq(1)
    expect(item.reload).to be_pending
    expect(request.reload).to be_pending
    expect(ChatPendingAction.count).to eq(1)
    expect(request.transitions.where(event_type: described_class::EVALUATED_EVENT).count).to eq(1)
  end

  it "reevaluates an identical resubmission when new transcript evidence is attached" do
    responses = [
      { outcome: :escalate, rationale: "Unclear intent", policy_factors: [], confidence: 1.0, evidence: {} },
      outcome
    ]
    allow(provider).to receive(:decide) { |evidence| calls << evidence; responses.shift }

    expect(run).to be_escalated
    later = transcript + [ { role: "user", content: "Yes, restart cluster 7" } ]
    result = run(transcript: later)

    expect(result).to be_approved
    expect(calls.last["transcript"].size).to eq(2)
    expect(request.transitions.where(event_type: described_class::EVALUATED_EVENT).count).to eq(2)
    expect(AuthorizedInvocation.where(pending_action_item: item).count).to eq(1)
  end

  it "reconsiders when only secret-bearing evidence differs" do
    allow(provider).to receive(:decide) { calls << :asked; { outcome: :escalate, rationale: "Unsure", policy_factors: [], confidence: 1.0, evidence: {} } }

    expect(run(transcript: [ { role: "user", content: "token=aaaaaaaaaaaaaaaaaaaa" } ])).to be_escalated
    expect(run(transcript: [ { role: "user", content: "token=bbbbbbbbbbbbbbbbbbbb" } ])).to be_escalated
    expect(calls.size).to eq(2)
    expect(request.transitions.where(event_type: described_class::EVALUATED_EVENT).last.metadata.to_json).not_to include("aaaaaaaa")
  end

  it "escalates without a delegation and never calls the provider" do
    delegation.destroy!

    expect(run).to be_escalated
    expect(calls).to be_empty
    expect(request.reload).to be_pending
  end

  it "skips requests with more than one item" do
    request.authorization_items.create!(kind: "capability_possession", capability: "k8s.workload", resource_type: "cluster",
      resource_scope: {}, normalized_arguments: {}, effects: [], policy_chain: [], decisive_rule: {}, requested_durations: [ "job" ])

    expect(run).to be_skipped
    expect(calls).to be_empty
  end
end

RSpec.describe Permissions::AuthorizationRequestRouter, "AI approval wiring", :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:) }
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ApprovalProvider
      def self.provider_key = "reviewer"
      def self.display_name = "Reviewer"
      def self.data_sharing = "Sent."
      def self.default_guidance = "Careful."
      def self.decide(_evidence) = { outcome: :allow, rationale: "ok", policy_factors: [], confidence: 0.95, evidence: {} }
    end
  end

  it "evaluates a newly routed request and skips human notification once approved" do
    ApprovalProviderDelegation.create!(owner_user: user, provider_key: "reviewer", capability: "k8s.workload",
      resource_type: "cluster", resource_scope: { cluster_id: 7 })
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:approval_provider).and_return([ provider ])
    expect(ApprovalNotifications::Router).not_to receive(:route!)

    result = described_class.route!(user:, repository:, origin: job, subject: user, runtime_role: "implementer",
      deduplication_key: "agent:#{user.id}:k8s:wired", purpose: "Restart", capability: "k8s.workload", operation: "restart",
      ai_approval: { tool_name: "restart_workload", transcript: [ { role: "user", content: "restart" } ] },
      item_attributes: { kind: "operation", operation_version: 1, resource_type: "cluster", resource_scope: { cluster_id: 7 },
        invocation_fingerprint: "sha256:wired", normalized_arguments: {}, effects: [ "operational" ],
        policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation] })

    expect(result.request.reload).to be_confirmed
    expect(AuthorizedInvocation.count).to eq(1)
  end
end
