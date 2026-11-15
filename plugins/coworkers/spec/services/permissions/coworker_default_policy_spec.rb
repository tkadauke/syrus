require "rails_helper"

RSpec.describe Permissions::CoworkerDefaultPolicy do
  def descriptor(effects:, risk: :low, default: :allow, benign_internal: nil, classifier: nil, roles: described_class::ROLES)
    operation = "spec.default/probe@v1"
    Permissions::CapabilityDescriptor.new(
      capability: "spec.default@v1", operation:, effects:, risk:, requestable_roles: roles,
      defaults: roles.index_with { default }, maximum_autonomy: :invocation, authority_durations: [ :invocation ],
      resource_scope: { type: :none }, benign_internal:,
      classifier: classifier || ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  describe ".auto_allowable?" do
    it "allows only low-risk local reads and isolated workspace writes" do
      expect(described_class.auto_allowable?(effects: %i[local_read], risk: :low)).to be(true)
      expect(described_class.auto_allowable?(effects: %i[local_read isolated_workspace_write], risk: :low)).to be(true)
      expect(described_class.auto_allowable?(effects: %i[local_read], risk: :medium)).to be(false)
    end

    it "treats internal_write as benign only when the descriptor names a benign kind" do
      expect(described_class.auto_allowable?(effects: %i[internal_write], risk: :low)).to be(false)
      expect(described_class.auto_allowable?(effects: %i[internal_write], risk: :low, benign_internal: :draft_proposal)).to be(true)
    end

    %i[confidential_read network_read credential_use external_write communication financial privilege_change
       operational destructive irreversible persistent_autonomy isolated_execution operator_host_access].each do |effect|
      it "never auto-allows #{effect}, even beside a benign kind" do
        expect(described_class.auto_allowable?(effects: [ :internal_write, effect ], risk: :low, benign_internal: :context_binding)).to be(false)
      end
    end
  end

  describe "descriptor validation" do
    it "rejects a benign kind on a descriptor with risky effects or risk" do
      expect { descriptor(effects: %i[internal_write communication], benign_internal: :owner_interaction) }.to raise_error(ArgumentError, /benign internal/)
      expect { descriptor(effects: %i[internal_write], risk: :medium, benign_internal: :owner_interaction) }.to raise_error(ArgumentError, /benign internal/)
      expect { descriptor(effects: %i[internal_write], benign_internal: :anything) }.to raise_error(ArgumentError, /unknown benign/)
    end

    it "reports a contradictory allow default" do
      unsafe = descriptor(effects: %i[internal_write], default: :allow)
      expect(described_class.violations(unsafe).first).to match(/defaults to allow.*not fully benign/)
      expect { described_class.validate!(unsafe) }.to raise_error(ArgumentError)
      expect(described_class.violations(descriptor(effects: %i[internal_write], default: :ask))).to be_empty
      expect(described_class.violations(descriptor(effects: %i[local_read]))).to be_empty
    end

    it "rejects registering a coworker tool that silently inherits an unsafe allow" do
      tool = Class.new(MCP::Tool) { tool_name "future_unsafe_coworker_tool" }
      unsafe = descriptor(effects: %i[confidential_read], default: :allow)

      expect do
        McpToolRegistry.send(:entry, tool, surface: :coworker, descriptor: unsafe)
      end.to raise_error(ArgumentError, /not fully benign/)
      expect { McpToolRegistry.send(:entry, tool, surface: :coworker, mutation: true, required_roles: described_class::ROLES) }.not_to raise_error
    end

    it "gives legacy mutating coworker registrations the ask default" do
      tool = Class.new(MCP::Tool) { tool_name "future_mutating_coworker_tool" }
      entry = McpToolRegistry.send(:entry, tool, surface: :coworker, mutation: true, required_roles: described_class::ROLES)

      expect(entry.descriptor.defaults.values.uniq).to eq([ :ask ])
    end
  end

  describe "dynamic argument classification" do
    it "downgrades an allow default to ask when this invocation classifies as risky" do
      operation = "spec.default/probe@v1"
      dynamic = descriptor(
        effects: %i[local_read confidential_read], risk: :medium, default: :allow,
        classifier: lambda { |arguments|
          if arguments[:scope] == "public"
            { operation:, effects: %i[local_read], risk: :low, confidence: :certain }
          else
            { operation:, effects: %i[confidential_read], risk: :medium, confidence: :certain }
          end
        }
      )
      evaluate = lambda do |arguments|
        Permissions::PolicyEvaluator.new(descriptor: dynamic, role: AgentRole::COWORKER_CHAT, resource_scope: {}, arguments:).call
      end

      expect(evaluate.call(scope: "public").policy).to eq(:allow)
      risky = evaluate.call(scope: "private")
      expect(risky.policy).to eq(:ask)
      expect(risky.chain.last.detail).to eq(:unsafe_classification)
    end

    it "asks when the classifier fails or is ambiguous" do
      broken = descriptor(effects: %i[local_read], classifier: ->(_arguments) { raise "boom" })
      decision = Permissions::PolicyEvaluator.new(descriptor: broken, role: AgentRole::COWORKER_CHAT, resource_scope: {}).call

      expect(decision.policy).to eq(:ask)
    end

    it "does not touch non-coworker roles" do
      chat_descriptor = descriptor(effects: %i[internal_write], default: :allow, roles: [ AgentRole::CHAT_ROLES.first ])
      decision = Permissions::PolicyEvaluator.new(descriptor: chat_descriptor, role: AgentRole::CHAT_ROLES.first, resource_scope: {}).call

      expect(decision.policy).to eq(:allow)
    end
  end

  describe "explicit rules over defaults" do
    let(:benign) { Permissions::CoworkerActions.descriptor_for("propose_job") }

    def rule(policy:, layer: :agent)
      Permissions::PolicyRule.new(id: policy.to_s, layer:, policy:, source: "spec", capability: benign.capability,
        operation: benign.operation, resource_scope: nil)
    end

    it "lets an explicit deny beat the allow default" do
      decision = Permissions::PolicyEvaluator.new(descriptor: benign, role: AgentRole::COWORKER_CHAT, resource_scope: {},
        rules: [ rule(policy: :deny) ]).call

      expect(decision.policy).to eq(:deny)
    end

    it "lets an explicit ask rule beat the allow default" do
      decision = Permissions::PolicyEvaluator.new(descriptor: benign, role: AgentRole::COWORKER_CHAT, resource_scope: {},
        rules: [ rule(policy: :ask) ]).call

      expect(decision.policy).to eq(:ask)
    end
  end

  describe Permissions::CoworkerActions do
    it "derives grant defaults from the descriptor table" do
      expect(described_class.grant_default_policy("code.read")).to eq("auto")
      expect(described_class.grant_default_policy("syrus.propose_job")).to eq("auto")
      expect(described_class.grant_default_policy("ops.read_logs")).to eq("confirm")
      expect(described_class.grant_default_policy("chats.read_shared")).to eq("confirm")
    end

    it "gives attach and detach explicit read-only context descriptors instead of generic internal writes" do
      %w[attach_repository detach_repository].each do |name|
        descriptor = described_class.descriptor_for(name)
        expect(descriptor.benign_internal).to eq(:context_binding)
        expect(descriptor.risk).to eq(:low)
        expect(descriptor.defaults.values.uniq).to eq([ :allow ])
        expect(descriptor.maximum_autonomy).to eq(:invocation)
      end
    end

    it "refuses to build a descriptor whose allow default is not justified" do
      expect do
        described_class.descriptor(tool_name: "x", family: "spec.x", effects: %i[communication], risk: :low, default: :allow)
      end.to raise_error(ArgumentError, /not fully benign/)
    end

    it "keeps every core coworker registration consistent with the table" do
      McpToolRegistry.entries(surface: :coworker).each do |entry|
        expect(described_class.covers?(entry.tool_name)).to be(true), "#{entry.tool_name} is missing from CoworkerActions"
        expect(entry.explicit_descriptor).to be(true)
        expect(described_class.send(:const_get, :OPERATIONS).fetch(entry.tool_name).default).to eq(entry.descriptor.defaults.values.first)
      end
    end
  end
end
