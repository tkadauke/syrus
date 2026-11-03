require "rails_helper"

RSpec.describe "Permissions fresh authentication and budget hooks" do
  def descriptor(**overrides)
    Permissions::CapabilityDescriptor.new(**{
      capability: "example.data@v1", operation: "example.data/write@v1",
      effects: [ :external_write ], risk: :medium, requestable_roles: [ "chat_planner" ],
      defaults: { chat_planner: :allow }, maximum_autonomy: :job,
      authority_durations: %i[invocation job], resource_scope: { type: :none },
      classifier: ->(_arguments) { { operation: "example.data/write@v1" } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    }.merge(overrides))
  end

  def decide(desc, role: "chat_planner")
    Permissions::PolicyEvaluator.new(descriptor: desc, role:, resource_scope: {}).call
  end

  after { Permissions::EffectMetadata.reset! }

  describe "descriptor metadata" do
    it "defaults to no requirement and no budget dimensions" do
      expect(descriptor.requires_fresh_authentication?).to be(false)
      expect(descriptor.budget_dimensions).to eq([])
    end

    it "includes both in the contract and rejects unknown dimensions" do
      expect(descriptor(fresh_authentication_window: 5.minutes).contract_key).not_to eq(descriptor.contract_key)
      expect(descriptor(budget_dimensions: [ :storage ]).contract_key).not_to eq(descriptor.contract_key)
      expect { descriptor(budget_dimensions: [ :bogus ]) }.to raise_error(ArgumentError, /budget dimensions/)
      expect { descriptor(fresh_authentication_window: "soon") }.to raise_error(ArgumentError, /fresh authentication/)
    end
  end

  describe Permissions::FreshAuthentication do
    let(:now) { Time.current }
    let(:desc) { descriptor(fresh_authentication_window: 10.minutes) }

    it "lowers allow to ask when the authentication is stale or unknown" do
      expect(described_class.apply(:allow, descriptor: desc, authenticated_at: now - 1.hour, now:).first).to eq(:ask)
      policy, applied = described_class.apply(:allow, descriptor: desc, authenticated_at: nil, now:)
      expect(policy).to eq(:ask)
      expect(applied.reason).to eq(:fresh_authentication_required)
    end

    it "leaves fresh authentication, ask, and deny untouched and never raises" do
      expect(described_class.apply(:allow, descriptor: desc, authenticated_at: now - 1.minute, now:)).to eq([ :allow, nil ])
      expect(described_class.apply(:ask, descriptor: desc, authenticated_at: nil, now:)).to eq([ :ask, nil ])
      expect(described_class.apply(:deny, descriptor: desc, authenticated_at: nil, now:)).to eq([ :deny, nil ])
      expect(described_class.apply(:allow, descriptor: descriptor, authenticated_at: nil, now:)).to eq([ :allow, nil ])
    end
  end

  describe Permissions::EffectMetadata do
    let(:desc) { descriptor(budget_dimensions: %i[model_tokens storage]) }

    it "notifies observers with effect metadata and never changes the decision" do
      seen = []
      described_class.register(:meter) { |record| seen << record; :deny }
      described_class.register(:broken) { |_record| raise "boom" }
      decision = decide(desc)

      expect(described_class.notify(desc, decision, logger: Logger.new(nil))).to equal(decision)
      expect(decision.policy).to eq(:allow)
      expect(seen.first.to_h).to include(capability: "example.data@v1", budget_dimensions: %i[model_tokens storage], policy: :allow)
    end

    it "skips denied decisions and descriptors without budget dimensions" do
      seen = []
      described_class.register(:meter) { |record| seen << record }
      described_class.notify(desc, decide(desc, role: "unknown"))
      described_class.notify(descriptor, decide(descriptor))
      expect(seen).to be_empty
    end
  end

  describe Permissions::CapabilityUpgradeValidator do
    it "treats dropping or lengthening a fresh-authentication window as widening" do
      previous = descriptor(fresh_authentication_window: 5.minutes)
      [ descriptor, descriptor(fresh_authentication_window: 1.hour) ].each do |current|
        findings = described_class.new(previous: [ previous ], current: [ current ]).findings
        expect(findings.map(&:code)).to include(:semantic_widening)
      end
      expect(described_class.new(previous: [ previous ], current: [ descriptor(fresh_authentication_window: 1.minute) ]).findings).to be_empty
    end

    it "does not treat budget metadata as authority" do
      expect(described_class.new(previous: [ descriptor ], current: [ descriptor(budget_dimensions: [ :storage ]) ]).findings).to be_empty
    end
  end
end
