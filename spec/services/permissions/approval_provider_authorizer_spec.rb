require "rails_helper"

RSpec.describe Permissions::ApprovalProviderAuthorizer do
  let(:owner) { Factories.user }
  let(:request) do
    Permissions::ApprovalProviderRequest.new(owner:, capability: "k8s.workload@v1", operation: "restart@v1",
      resource_type: "cluster", resource_scope: { cluster_id: 7 }, effects: [ "operational" ],
      invocation_fingerprint: "sha256:exact", transcript: [ { role: "user", content: "Restart it" } ],
      tool_call: { name: "restart", arguments: { id: 7 } }, policy_chain: [ { layer: "resource", policy: "ask" } ])
  end
  let(:provider) do
    Class.new do
      include Syrus::Plugin::ApprovalProvider
      def self.provider_key = "reviewer"
      def self.display_name = "Reviewer"
      def self.decide(_request)
        { outcome: :allow, rationale: "Policy permits this exact restart", policy_factors: [ "bounded_resource" ],
          confidence: 0.91, evidence: { "cluster_id" => 7 } }
      end
    end
  end
  let(:delegation) do
    ApprovalProviderDelegation.create!(owner_user: owner, provider_key: "reviewer",
      capability: request.capability, resource_type: request.resource_type,
      resource_scope: request.resource_scope, excluded_effects: [])
  end

  it "allows one exact invocation only through an explicit user delegation" do
    result = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])

    expect(result).to be_allowed
    expect(result.decision.to_h).to include(outcome: :allow, confidence: 0.91)
    expect(result.delegation).to eq(delegation)
    expect(result.authority_duration).to eq(:invocation)
    expect(result.invocation_fingerprint).to eq("sha256:exact")
  end

  it "escalates without invoking a provider when no delegation covers the call" do
    expect(provider).not_to receive(:decide)
    result = described_class.call(request:, delegations: [], providers: [ provider ])

    expect(result).to be_escalated
    expect(result.decision.provider_outcome).to eq("not_delegated")
  end

  it "keeps financial, privilege, and permission-management decisions human-only" do
    attributes = { owner:, operation: "manage@v1", resource_type: "account", resource_scope: {},
      invocation_fingerprint: "sha256:human", transcript: [], tool_call: {}, policy_chain: [] }
    privileged = Permissions::ApprovalProviderRequest.new(**attributes,
      capability: request.capability, effects: [ "privilege_change" ])
    permission = Permissions::ApprovalProviderRequest.new(**attributes,
      capability: "syrus.permissions@v1", effects: [ "internal_write" ])

    expect(described_class.call(request: privileged, delegations: [ delegation ], providers: [ provider ])).to be_escalated
    expect(described_class.call(request: permission, delegations: [ delegation ], providers: [ provider ])).to be_escalated
  end

  it "applies additional plugin and resource ceilings before calling the provider" do
    expect(provider).not_to receive(:decide)
    result = described_class.call(request:, delegations: [ delegation ], providers: [ provider ],
      ceiling_rules: [ ->(_invocation) { false } ])

    expect(result).to be_escalated
    expect(result.decision.provider_outcome).to eq("ceiling")
  end

  it "enforces non-delegable ceilings from the effective policy chain" do
    ceiling_request = request_with(policy_chain: [
      { layer: :resource, policy: :ask, rule: { delegable: false, policy: :ask } }
    ])
    expect(provider).not_to receive(:decide)

    result = described_class.call(request: ceiling_request, delegations: [ delegation ], providers: [ provider ])

    expect(result).to be_escalated
    expect(result.decision.provider_outcome).to eq("ceiling")
  end

  it "escalates uncertain allows and provider-managed outcomes" do
    allow(provider).to receive(:decide).and_return(outcome: :allow, rationale: "Uncertain",
      policy_factors: [], confidence: 0.79, evidence: {})
    uncertain = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])
    expect(uncertain.decision.provider_outcome).to eq("uncertain")

    allow(provider).to receive(:decide).and_return(outcome: :allow, rationale: "Quota exhausted",
      policy_factors: [ "rate" ], confidence: 1, evidence: {}, provider_outcome: "rate_limited")
    limited = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])
    expect(limited).to be_escalated
    expect(limited.decision.provider_outcome).to eq("rate_limited")
  end

  it "redacts provider evidence before returning it" do
    allow(provider).to receive(:decide).and_return(outcome: :deny, rationale: "Secret detected",
      policy_factors: [], confidence: 1, evidence: { api_token: "secret-value" })

    result = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])

    expect(result.decision.evidence).to eq("api_token" => "[redacted]")
  end

  it "escalates unavailable, invalid, and plugin-managed rate outcomes" do
    unavailable = described_class.call(request:, delegations: [ delegation ], providers: [])
    expect(unavailable.decision.provider_outcome).to eq("provider_unavailable")

    allow(provider).to receive(:decide).and_return(outcome: :escalate, rationale: "Provider rate limit",
      policy_factors: [ "rate" ], confidence: 1, evidence: {}, provider_outcome: "rate_limited")
    limited = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])
    expect(limited.decision.to_h).to include(outcome: :escalate, provider_outcome: "rate_limited")

    allow(provider).to receive(:decide).and_return(outcome: :maybe)
    invalid = described_class.call(request:, delegations: [ delegation ], providers: [ provider ])
    expect(invalid.decision.provider_outcome).to eq("invalid_provider_output")
  end

  def request_with(**attributes)
    values = {
      owner:, capability: request.capability, operation: request.operation,
      resource_type: request.resource_type, resource_scope: request.resource_scope,
      effects: request.effects, invocation_fingerprint: request.invocation_fingerprint,
      transcript: request.transcript, tool_call: request.tool_call, policy_chain: request.policy_chain
    }
    Permissions::ApprovalProviderRequest.new(**values.merge(attributes))
  end
end
