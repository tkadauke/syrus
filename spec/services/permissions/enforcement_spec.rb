require "rails_helper"

# The master switch. A permission system is a classification of every tool,
# and one tool classified wrong can make the product unusable -- a draft an
# operator must confirm anyway asking for permission first, a confirmation
# that cannot be given. These examples pin the one guarantee the switch makes:
# off means allowed, everywhere, including the paths that lower a policy
# without going through the evaluator's rule chain.
RSpec.describe Permissions::Enforcement do
  let(:schema) do
    Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: ->(scope, context:) { { repository_id: Integer(scope[:repository_id]) } },
      compare: ->(left, right, context:) { left == right ? :equal : :disjoint }
    )
  end

  def descriptor(effects: [ :external_write ], risk: :high, fresh_authentication_window: nil)
    Permissions::CapabilityDescriptor.new(
      capability: "workspace.files@v1", operation: "workspace.files/write@v1",
      effects: effects, risk: risk,
      requestable_roles: %w[implementer], defaults: { implementer: :ask },
      maximum_autonomy: :job, authority_durations: %i[invocation job], resource_scope: schema,
      classifier: ->(_arguments) { { operation: "workspace.files/write@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments },
      fresh_authentication_window: fresh_authentication_window
    )
  end

  def rule(policy)
    Permissions::PolicyRule.new(id: "spec", layer: :instance, policy: policy, source: "spec")
  end

  def evaluate(rules: [], target: descriptor)
    Permissions::PolicyEvaluator.new(
      descriptor: target, role: "implementer", resource_scope: { repository_id: 1 }, rules: rules
    ).call
  end

  def disable_enforcement!
    AppSetting.current.update!(permissions_enforced: false)
  end

  describe ".enforced?" do
    it "is on by default, so the switch is only ever a deliberate act" do
      expect(described_class.enforced?).to be(true)
      expect(described_class.disabled?).to be(false)
    end

    it "follows the setting" do
      disable_enforcement!

      expect(described_class.enforced?).to be(false)
      expect(described_class.disabled?).to be(true)
    end

    # Regression: the switch is read on the agent-launch path, so reading it
    # unconditionally broke every new run on the workers, which had booted
    # before the column landed and so had no method for it -- the failure
    # rollout_compatibility.md calls rule 1. The answer when the column is
    # absent is the behaviour from before the switch existed: enforced.
    it "enforces on a process whose schema snapshot predates the column" do
      setting = AppSetting.current
      allow(setting).to receive(:has_attribute?).and_call_original
      allow(setting).to receive(:has_attribute?).with(:permissions_enforced).and_return(false)
      allow(setting).to receive(:permissions_enforced).and_raise(
        NoMethodError, "undefined method 'permissions_enforced' for an instance of AppSetting"
      )
      allow(AppSetting).to receive(:current).and_return(setting)

      expect(described_class.enforced?).to be(true)
      expect(described_class.disabled?).to be(false)
    end

    it "evaluates a policy without raising on that schema snapshot" do
      setting = AppSetting.current
      allow(setting).to receive(:has_attribute?).and_call_original
      allow(setting).to receive(:has_attribute?).with(:permissions_enforced).and_return(false)
      allow(setting).to receive(:permissions_enforced).and_raise(
        NoMethodError, "undefined method 'permissions_enforced' for an instance of AppSetting"
      )
      allow(AppSetting).to receive(:current).and_return(setting)

      expect { evaluate }.not_to raise_error
      expect(evaluate.policy).to eq(:ask)
    end

    it "enforces when the settings row was loaded without the column" do
      partial = AppSetting.select(:id).find_by!(id: AppSetting.current.id)
      expect(partial.has_attribute?(:permissions_enforced)).to be(false)
      allow(AppSetting).to receive(:current).and_return(partial)

      expect(described_class.enforced?).to be(true)
    end
  end

  describe "with enforcement on" do
    it "still asks where the policy says ask" do
      expect(evaluate.policy).to eq(:ask)
    end

    it "still denies where a rule says deny" do
      expect(evaluate(rules: [ rule(:deny) ]).policy).to eq(:deny)
    end
  end

  describe "with enforcement off" do
    before { disable_enforcement! }

    it "allows what the role default would have asked about" do
      decision = evaluate

      expect(decision.policy).to eq(:allow)
      expect(decision).to be_allow
    end

    it "allows what an explicit rule would have denied" do
      expect(evaluate(rules: [ rule(:deny) ]).policy).to eq(:allow)
    end

    it "records why it allowed, so an audit does not read as a normal grant" do
      decision = evaluate

      expect(decision.chain.map(&:detail)).to eq([ :enforcement_disabled ])
      expect(decision.decisive_rule).to be_nil
    end

    it "reports the invocation it allowed" do
      decision = evaluate

      expect(decision.invocation.capability).to eq("workspace.files@v1")
      expect(decision.invocation.operation).to eq("workspace.files/write@v1")
    end

    it "does not consult the resource scope, so an unnormalizable scope still allows" do
      decision = Permissions::PolicyEvaluator.new(
        descriptor: descriptor, role: "implementer", resource_scope: { repository_id: "not-a-number" }, rules: []
      ).call

      expect(decision.policy).to eq(:allow)
    end

    it "allows a role the descriptor does not list, because no rule is consulted" do
      decision = Permissions::PolicyEvaluator.new(
        descriptor: descriptor, role: "reviewer", resource_scope: { repository_id: 1 }, rules: []
      ).call

      expect(decision.policy).to eq(:allow)
    end
  end

  # Two paths lower a policy after the evaluator has spoken. Both have to
  # honor the switch or it would not reach the capabilities most likely to be
  # misclassified in the first place.
  describe "downgrades that bypass the rule chain" do
    let(:stale_descriptor) { descriptor(fresh_authentication_window: 5.minutes) }

    it "requires fresh authentication while enforcement is on" do
      policy, applied = Permissions::FreshAuthentication.apply(
        :allow, descriptor: stale_descriptor, authenticated_at: 1.hour.ago
      )

      expect(policy).to eq(:ask)
      expect(applied.reason).to eq(:fresh_authentication_required)
    end

    it "does not require fresh authentication once enforcement is off" do
      disable_enforcement!

      policy, applied = Permissions::FreshAuthentication.apply(
        :allow, descriptor: stale_descriptor, authenticated_at: 1.hour.ago
      )

      expect(policy).to eq(:allow)
      expect(applied).to be_nil
    end
  end
end

# A raw process is where the switch matters most: ExecutionAuthorization
# lowers an allow to an ask whenever the invocation carries a sensitive effect
# and no rule decided it -- which is exactly the shape of a bypassed
# decision, so a switch that stopped at the evaluator would leave every
# execution capability still asking.
RSpec.describe Permissions::ExecutionAuthorization, "with the permission master switch off" do
  def host(command)
    request = Execution::Request.new(**Execution::Request.members.index_with { nil }, command:, network: "agent", env: {})
    Permissions::ExecutionActions.subject_for_request(request, location: :host)
  end

  def authorize
    described_class.authorize(subject: host([ "sudo rm -rf /tmp/x" ]), role: AgentRole::WORKFLOW_IMPLEMENT)
  end

  it "downgrades a sensitive invocation to ask while enforcement is on" do
    expect(authorize.policy).to eq(:ask)
  end

  it "leaves the allow standing once enforcement is off" do
    AppSetting.current.update!(permissions_enforced: false)

    result = authorize

    expect(result.decision.policy).to eq(:allow)
    expect(result.policy).to eq(:allow)
    expect(result.fresh_authentication).to be_nil
    expect(result.ceilings).to be_empty
  end
end
