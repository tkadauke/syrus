require "rails_helper"

RSpec.describe Permissions::PolicyEvaluator do
  let(:schema) do
    Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: ->(scope, context:) do
        { repository_id: Integer(scope[:repository_id] || scope.fetch("repository_id")),
          path: (scope[:path] || scope["path"])&.to_s }
      end,
      compare: ->(left, right, context:) do
        next :disjoint unless left["repository_id"] == right["repository_id"]
        next :equal if left == right
        next :narrower if right["path"].nil? || left["path"]&.start_with?(right["path"])

        :disjoint
      end
    )
  end
  let(:classifier) { ->(_arguments) { { operation: "workspace.files/write@v1", confidence: :certain } } }
  let(:descriptor) { build_descriptor(classifier) }

  def build_descriptor(classification_hook)
    Permissions::CapabilityDescriptor.new(
      capability: "workspace.files@v1", operation: "workspace.files/write@v1",
      effects: [ :isolated_workspace_write ], risk: :medium,
      requestable_roles: %w[implementer reviewer], defaults: { implementer: :allow, reviewer: :deny },
      maximum_autonomy: :job, authority_durations: %i[invocation job], resource_scope: schema,
      classifier: classification_hook, fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  def rule(id, layer, policy, **attributes)
    Permissions::PolicyRule.new(id:, layer:, policy:, source: "spec", **attributes)
  end

  def evaluate(rules: [], role: "implementer", scope: { repository_id: 1, path: "app/models/job.rb" },
    context: {}, arguments: {})
    described_class.new(descriptor:, role:, resource_scope: scope, rules:, context:, arguments:).call
  end

  describe "deterministic layer resolution" do
    cases = [
      [ "core", :core ], [ "provider", :provider ], [ "resource", :resource ],
      [ "instance", :instance ], [ "team", :team ], [ "repository", :repository ],
      [ "role", :role ], [ "agent", :agent ], [ "lease", :lease ], [ "invocation", :invocation ]
    ]

    cases.each do |label, layer|
      it "includes and resolves the #{label} layer" do
        decision = evaluate(rules: [ rule(label, layer, :ask) ])

        expect(decision.policy).to eq(:ask)
        expect(decision.decisive_rule.id).to eq(label)
        expect(decision.chain.map(&:layer)).to include(*described_class::LAYERS)
        expect(decision.chain.find { |item| item.layer == layer }.status).to eq(:decisive)
      end
    end

    it "lets the most specific matching rule win within a layer" do
      rules = [
        rule("broad", :repository, :ask, capability: descriptor.capability),
        rule("specific", :repository, :allow, capability: descriptor.capability,
          operation: descriptor.operation, resource_scope: { repository_id: 1, path: "app" })
      ]

      expect(evaluate(rules:).decisive_rule.id).to eq("specific")
    end

    it "resolves equally specific rules toward less authority and then stable id" do
      rules = [ rule("z", :agent, :allow), rule("b", :agent, :ask), rule("a", :agent, :ask) ]

      expect(evaluate(rules:).decisive_rule.id).to eq("a")
    end

    it "makes an explicit deny decisive regardless of a narrower allow" do
      rules = [
        rule("instance-deny", :instance, :deny),
        rule("invocation-allow", :invocation, :allow, operation: descriptor.operation,
          resource_scope: { repository_id: 1, path: "app/models/job.rb" })
      ]

      decision = evaluate(rules:)
      expect(decision).to be_deny
      expect(decision.decisive_rule.id).to eq("instance-deny")
      expect(decision.chain.find { |item| item.rule&.id == "instance-deny" }.status).to eq(:decisive)
    end

    it "allows narrower rules to widen only through delegable parent layers" do
      delegable = [ rule("provider", :provider, :ask), rule("agent", :agent, :allow) ]
      ceiling = [ rule("provider", :provider, :ask, delegable: false), rule("agent", :agent, :allow) ]

      expect(evaluate(rules: delegable)).to be_allow
      capped = evaluate(rules: ceiling)
      expect(capped).to be_ask
      expect(capped.decisive_rule.id).to eq("provider")
      expect(capped.chain.find { |item| item.rule&.id == "provider" }.status).to eq(:decisive_ceiling)
    end

    it "uses the most restrictive of multiple non-delegable ceilings" do
      rules = [
        rule("core", :core, :allow, delegable: false),
        rule("resource", :resource, :ask, delegable: false),
        rule("lease", :lease, :allow)
      ]

      expect(evaluate(rules:).decisive_rule.id).to eq("resource")
    end

    it "preserves a broader non-delegable ceiling hidden by a same-layer winner" do
      rules = [
        rule("repository-ceiling", :repository, :ask, capability: descriptor.capability, delegable: false),
        rule("repository-allow", :repository, :allow, capability: descriptor.capability,
          operation: descriptor.operation, resource_scope: { repository_id: 1, path: "app" })
      ]

      decision = evaluate(rules:)
      expect(decision).to be_ask
      expect(decision.decisive_rule.id).to eq("repository-ceiling")
      expect(decision.chain.find { |item| item.rule&.id == "repository-ceiling" }.to_h).to include(
        status: :decisive_ceiling, policy: :ask, detail: :non_delegable
      )
      expect(decision.chain.find { |item| item.rule&.id == "repository-allow" }.status).to eq(:matched)
    end
  end

  describe "matching and fallbacks" do
    it "applies the role default only when no explicit rule matches" do
      reviewer = evaluate(role: "reviewer")
      implementer = evaluate

      expect(reviewer).to be_deny
      expect(implementer).to be_allow
      expect(implementer.decisive_rule).to be_nil
      expect(implementer.chain.last.to_h).to include(layer: :default, status: :decisive_default, detail: :role_default)
      expect(implementer.to_h.dig(:invocation, :classification, :confidence)).to eq(:certain)
    end

    it "matches selectors and containing resource scopes without leaking disjoint rules" do
      rules = [
        rule("wrong-agent", :agent, :deny, selectors: { agent_id: 8 }),
        rule("right-repo", :repository, :ask, resource_scope: { repository_id: 1, path: "app" }),
        rule("wrong-repo", :repository, :deny, resource_scope: { repository_id: 2 })
      ]

      decision = evaluate(rules:, context: { agent_id: 7 })
      expect(decision).to be_ask
      expect(decision.decisive_rule.id).to eq("right-repo")
    end

    it "fails closed when resource normalization fails" do
      decision = evaluate(scope: {})

      expect(decision).to be_deny
      expect(decision.chain.first.to_h).to include(status: :decisive_failure, detail: :resource_scope_failed)
    end

    it "fails closed when a matching rule's scope cannot be compared" do
      broken_schema = Permissions::ResourceScopeSchema.new(type: :repository, compare: ->(*) { raise "unavailable" })
      broken_descriptor = build_descriptor(classifier).to_h.merge(resource_scope: broken_schema)
      broken_descriptor = Permissions::CapabilityDescriptor.new(**broken_descriptor)
      decision = described_class.new(descriptor: broken_descriptor, role: "implementer",
        resource_scope: { repository_id: 1 },
        rules: [ rule("scoped", :repository, :allow, resource_scope: { repository_id: 1 }) ],
        context: {}, arguments: {}).call

      expect(decision).to be_deny
      expect(decision.chain.first.detail).to eq(:resource_scope_comparison_failed)
    end

    [
      [ "raises", ->(*) { raise "ambiguous" }, :classifier_failure ],
      [ "reports uncertainty", ->(*) { { operation: "workspace.files/read@v1", confidence: :uncertain } }, :ambiguous_classifier ],
      [ "returns invalid effects", ->(*) { { effects: [ :unknown ], confidence: :certain } }, :classifier_failure ]
    ].each do |label, failing_classifier, reason|
      it "uses the declared maximum-risk classification when the classifier #{label}" do
        failing_descriptor = build_descriptor(failing_classifier)
        decision = described_class.new(descriptor: failing_descriptor, role: "implementer",
          resource_scope: { repository_id: 1 }, rules: [], context: {}, arguments: {}).call
        classification = decision.invocation.classification
        expect(classification).to be_fallback
        expect(classification.to_h).to include(operation: failing_descriptor.operation, effects: failing_descriptor.effects,
          risk: failing_descriptor.risk, confidence: :ambiguous, reason:)
      end
    end
  end

  it "validates rules at the boundary" do
    expect { rule("bad", :mystery, :allow) }.to raise_error(ArgumentError, /unknown policy layer/)
    expect { rule("bad", :core, :queue) }.to raise_error(ArgumentError, /unknown policy/)
  end

  it "keeps policy inputs immutable after construction" do
    scope = { repository_id: 1, paths: [ "app" ] }
    selectors = { agent_id: "agent-1" }
    policy_rule = rule("immutable", :agent, :allow, resource_scope: scope, selectors:)
    scope[:repository_id] = 2
    selectors[:agent_id] = "agent-2"

    expect(policy_rule.resource_scope).to eq(repository_id: 1, paths: [ "app" ])
    expect(policy_rule.selectors).to eq(agent_id: "agent-1")
    expect(policy_rule.resource_scope[:paths]).to be_frozen
  end
end
