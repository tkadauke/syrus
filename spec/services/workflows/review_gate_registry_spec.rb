require "rails_helper"

RSpec.describe Workflows::ReviewGateRegistry do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }
  let(:fake_provider) do
    Class.new do
      include Syrus::Plugin::ReviewGate

      class << self
        attr_accessor :gate_enabled
      end

      def self.review_gates
        [ {
          key: "synthetic", step_kind: "synthetic_review", slot: "after_agent",
          after: %w[security], before: %w[coworker],
          enabled_resolver: ->(job:, trigger_kind:, syrus_yml:, **) {
            gate_enabled != false && job.present? && trigger_kind.present? && [ nil, :project_overlay ].include?(syrus_yml)
          },
          loop_budget: 2, repair_step: ->(agent_step:, **) { agent_step },
          handler_provider: "Synthetic::ReviewStep", prompt_provider: "Synthetic::ReviewPrompt",
          tool_provider: %w[submit_synthetic_review], verdict_artifact: "synthetic_review_iterations",
          failure_policy: { "deterministic" => "fail", "transient" => "retry" },
          evidence_metadata: { "schema" => 1 }, panel_capable: true
        } ]
      end
    end
  end

  before do
    fake_provider.gate_enabled = true
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_gate).and_return([ fake_provider ])
    allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(double(enabled?: false, rounds: 0, source: "none", note: "disabled"))
    allow(RepoAdversarialReviewPlan).to receive(:from_syrus_yml).and_return(double(enabled?: false, rounds: 0, source: "none", note: "disabled"))
    allow(RepoSecurityReviewPlan).to receive(:for_job).and_return(double(enabled?: false, rounds: 0, source: "none", note: "disabled"))
    allow(RepoSecurityReviewPlan).to receive(:from_syrus_yml).and_return(double(enabled?: false, rounds: 0, source: "none", note: "disabled"))
    allow(RepoCoworkerReviewPlan).to receive(:for_job).and_return(double(enabled?: false, rounds: 0))
    allow(RepoCoworkerReviewPlan).to receive(:from_syrus_yml).and_return(double(enabled?: false, rounds: 0))
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(double(enabled?: false, rounds: 0))
    grade_plan = double(any_configured?: false, format_configured?: false, generate_configured?: false, graders_configured?: false)
    allow(RepoGradeLoopPlan).to receive(:for_job).and_return(grade_plan)
    allow(RepoGradeLoopPlan).to receive(:from_syrus_yml).and_return(grade_plan)
  end

  it "orders a synthetic plugin gate through stable before/after constraints" do
    keys = described_class.ordered(:after_agent).map(&:key)

    expect(keys).to eq(%w[adversarial security synthetic coworker visual])
  end

  it "resolves project-overlay enablement, loop budget, repair, and evidence metadata" do
    gates = described_class.for(
      slot: :after_agent, job: job, agent_step: :implement,
      trigger_kind: :initial, syrus_yml: :project_overlay
    )
    gate = gates.find { |candidate| candidate.key == "synthetic" }

    expect(gate).to be_present
    expect(gate.budget(job: job, agent_step: "implement", trigger_kind: "initial", syrus_yml: :project_overlay)).to eq(2)
    expect(gate.repair_step_for(job: job, agent_step: "implement", trigger_kind: "initial", syrus_yml: :project_overlay)).to eq("implement")
    expect(gate.snapshot).to include(
      "verdict_artifact" => "synthetic_review_iterations",
      "failure_policy" => { "deterministic" => "fail", "transient" => "retry" },
      "evidence_metadata" => { "schema" => 1 }, "panel_capable" => true
    )
  end

  it "re-resolves providers after registry reload or plugin disablement" do
    expect(described_class.active_for_step_kind("synthetic_review")).to be_present

    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_gate).and_return([])

    expect(described_class.active_for_step_kind("synthetic_review")).to be_nil
  end

  it "preserves the repair but removes the next review when a plugin is disabled between iterations" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_gate).and_return([])

    expect(
      described_class.continuation_steps(
        loop_steps: %w[implement synthetic_review],
        snapshotted_step_kinds: %w[synthetic_review],
        job: job,
        trigger_kind: :initial
      )
    ).to eq(%w[implement])
  end

  it "re-resolves contribution enablement between iterations" do
    fake_provider.gate_enabled = false

    expect(
      described_class.continuation_steps(
        loop_steps: %w[implement synthetic_review],
        snapshotted_step_kinds: %w[synthetic_review],
        job: job,
        trigger_kind: :initial
      )
    ).to eq(%w[implement])
  end

  it "rejects contribution ordering cycles" do
    cyclic_provider = Class.new do
      include Syrus::Plugin::ReviewGate
      def self.review_gates
        %w[first second].map do |key|
          {
            key: key, step_kind: "#{key}_review", after: [ key == "first" ? "second" : "first" ],
            enabled_resolver: ->(**) { true }, loop_budget: 1,
            handler_provider: "Fake", prompt_provider: "Fake", tool_provider: [ "submit_fake" ],
            verdict_artifact: "#{key}_iterations"
          }
        end
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_gate).and_return([ cyclic_provider ])

    expect { described_class.ordered(:after_agent) }.to raise_error(
      described_class::InvalidContribution, /ordering cycle/
    )
  end

  it "preserves the visual-review exclusion for external PR feedback" do
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(double(enabled?: true, rounds: 1))

    gates = described_class.for(
      slot: :after_agent,
      job: job,
      agent_step: :respond,
      trigger_kind: :external_pr_feedback
    )

    expect(gates.map(&:key)).to include("synthetic")
    expect(gates.map(&:key)).not_to include("visual")
  end

  it "lets every host workflow builder iterate the same contribution contract" do
    allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(:project_overlay)
    builders = [
      Workflows::Initial, Workflows::Retry, Workflows::PrFeedback,
      Workflows::ChatFeedback, Workflows::ExternalPrFeedback, Workflows::CodingHandoff
    ]

    builders.each do |builder|
      allow(builder).to receive(:resolve_default_branch_syrus_yml).and_return(:project_overlay) if builder.respond_to?(:resolve_default_branch_syrus_yml)
      chain = builder.steps_for(job)
      expect(chain.grep(Workflows::Loop).map { |loop| loop.steps.last }).to include("synthetic_review"), builder.name
    end
  end
end
