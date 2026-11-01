require "rails_helper"

RSpec.describe Permissions::ShadowEvaluator do
  let(:user) { Factories.user }
  let(:context) { McpToolContext.new(surface: :run, role: AgentRole::WORKFLOW_IMPLEMENT, user:) }

  def entry(tool)
    McpToolRegistry.entry_for(tool)
  end

  it "records a current-versus-shadow mismatch without changing current dispatch" do
    registration = entry(Mcp::Tools::SubmitSummaryTool)
    allow(OperationalLogging).to receive(:ingest)

    result = described_class.new(entry: registration, context:, currently_allowed: true).call

    expect(result.to_h).to include(current_policy: :allow, shadow_policy: :ask, status: :mismatch)
    expect(OperationalLogging).to have_received(:ingest).with(hash_including(
      source: described_class::LOG_SOURCE,
      message: "Permission shadow decision differs from current dispatch"
    ))
    expect(McpToolRegistry.tools_for_context(context, surface: :workflow)).to include(Mcp::Tools::SubmitSummaryTool)
  end

  it "preserves an explicitly safe local operation when evaluation fails" do
    registration = entry(Mcp::Tools::ReadLiveStateTool)
    broken_evaluator = class_double(Permissions::PolicyEvaluator)
    allow(broken_evaluator).to receive(:new).and_raise("policy store unavailable")
    allow(OperationalLogging).to receive(:ingest)

    result = described_class.new(entry: registration, context:, currently_allowed: true,
      evaluator: broken_evaluator).call

    expect(result.to_h).to include(current_policy: :allow,
      status: :evaluation_failed_safe_local, safe_local: true)
    expect(result.shadow_policy).to be_nil
  end

  it "pins representative current and north-star decisions in parity fixtures" do
    fixtures = YAML.load_file(Rails.root.join("spec/fixtures/permission_parity.yml"))

    fixtures.each_value do |fixture|
      fixture_context = McpToolContext.new(surface: :run, role: fixture.fetch("role"), user:)
      registration = McpToolRegistry.entries.find { |candidate| candidate.tool_name == fixture.fetch("tool") }
      current = fixture.fetch("current_policy") == "allow"
      allow(OperationalLogging).to receive(:ingest)

      result = described_class.new(entry: registration, context: fixture_context, currently_allowed: current).call
      expect(result.current_policy).to eq(fixture.fetch("current_policy").to_sym)
      expect(result.shadow_policy).to eq(fixture.fetch("shadow_policy").to_sym)
    end
  end
end
