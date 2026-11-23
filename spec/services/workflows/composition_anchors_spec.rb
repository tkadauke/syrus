require "rails_helper"

RSpec.describe Workflows::CompositionAnchors, :reset_plugin_registry do
  module WorkflowCompositionFixture
    class Kinds
      include Syrus::Plugin::WorkflowKinds

      def self.step_kinds
        [
          { kind: "fixture_judge", handler: "Prepare", label: "Fixture judge", style: "bg-gray-100", agentic: false },
          { kind: "fixture_post_implementation", handler: "Prepare", label: "Fixture post implementation", style: "bg-gray-100", agentic: false, fail_policy: :advance },
          { kind: "fixture_post_implementation_later", handler: "Prepare", label: "Fixture later post implementation", style: "bg-gray-100", agentic: false },
          { kind: "fixture_post_pr", handler: "Prepare", label: "Fixture post PR", style: "bg-gray-100", agentic: false, fail_policy: :advance }
        ]
      end
    end

    class Judge
      def self.judges
        [
          { step_kind: "fixture_judge", order: 20, trigger_kinds: %w[initial retry], rounds_for: ->(job) { enabled?(job) ? 2 : 0 } }
        ]
      end

      def self.enabled?(job) = job.is_a?(Job) || job.title == "enabled"
    end

    class PostImplementation
      def self.post_implementation
        [ { step_kind: "fixture_post_implementation", order: 10, enabled_for: ->(job) { job.is_a?(Job) || job.title == "enabled" } } ]
      end
    end

    class PostPr
      def self.post_pr
        [ { step_kind: "fixture_post_pr", order: 30, enabled_for: ->(job) { job.is_a?(Job) || job.title == "enabled" }, fail_policy: :advance } ]
      end
    end
  end

  before do
    Syrus::PluginRegistry.register(
      name: "workflow_composition_fixture",
      version: "1.0.0",
      provides: {
        workflow_kinds: WorkflowCompositionFixture::Kinds,
        "workflow:judge" => WorkflowCompositionFixture::Judge,
        "workflow:post_implementation" => WorkflowCompositionFixture::PostImplementation,
        "workflow:post_pr" => WorkflowCompositionFixture::PostPr
      }
    )
  end

  let(:enabled_job) { Struct.new(:title).new("enabled") }
  let(:disabled_job) { Struct.new(:title).new("disabled") }

  it "builds an ordered review-first judge loop and round-trips through chain_template" do
    loop_node = described_class.judges(job: enabled_job, trigger_kind: "initial", agent_step: :implement).sole

    expect(loop_node.step_kinds).to eq([ "fixture_judge" ])
    expect(loop_node.to_chain_template).to eq(
      "type" => "loop",
      "max_iterations" => 2,
      "steps" => %w[implement fixture_judge]
    )
  end

  it "lets a workflow steps_for compose all three anchors around its fixed chain" do
    workflow_class = Class.new(Workflows::Base) do
      def self.trigger_kind = "initial"

      def self.steps_for(job)
        [
          "implement",
          judge_loops(job, agent_step: :implement),
          post_implementation_steps(job),
          "pr_open",
          post_pr_steps(job)
        ].flatten
      end
    end

    serialized = workflow_class.serialize_chain_template(workflow_class.steps_for(enabled_job))

    expect(serialized.map { |node| node["type"] == "loop" ? node.dig("steps", 1) : node["kind"] }).to eq(
      %w[implement fixture_judge fixture_post_implementation pr_open fixture_post_pr]
    )
    expect(serialized.second).to include("max_iterations" => 2, "steps" => %w[implement fixture_judge])
  end

  it "persists fixture contributions in an Initial chain and materializes them again" do
    job = Factories.job_record(state: "open")
    loaded = RepoDefaultBranchSyrusYml::Result.new(config: nil, source: "none", note: "stubbed")
    allow(RepoDefaultBranchSyrusYml).to receive(:for_job).and_return(loaded)
    allow(RepoAdversarialReviewPlan).to receive(:from_syrus_yml).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
    allow(RepoSecurityReviewPlan).to receive(:from_syrus_yml).and_return(
      RepoSecurityReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: false, rounds: 0, source: "none", note: "disabled")
    )
    allow(RepoGradeLoopPlan).to receive(:from_syrus_yml).and_return(
      RepoGradeLoopPlan::Result.new(
        format_configured: false, generate_configured: false, graders_configured: false,
        source: "none", note: "disabled"
      )
    )

    workflow = Workflows::Initial.instantiate(job:)

    expect(workflow.chain_template).to include(
      include("type" => "loop", "steps" => %w[implement fixture_judge]),
      include("type" => "step", "kind" => "fixture_post_implementation"),
      include("type" => "step", "kind" => "fixture_post_pr")
    )
    expect(workflow.steps.order(:position).pluck(:kind)).to include(
      "fixture_judge", "fixture_post_implementation", "fixture_post_pr"
    )
  end

  it "filters judges by trigger kind and rounds_for" do
    expect(described_class.judges(job: enabled_job, trigger_kind: "pr_comment", agent_step: :respond)).to be_empty
    expect(described_class.judges(job: disabled_job, trigger_kind: "initial", agent_step: :implement)).to be_empty
  end

  it "gates positioned contributions and preserves their fail policy" do
    expect(described_class.post_implementation(job: enabled_job)).to eq([ "fixture_post_implementation" ])
    expect(described_class.post_pr(job: enabled_job)).to eq([ "fixture_post_pr" ])
    expect(described_class.post_implementation(job: disabled_job)).to be_empty
    expect(Step::Kind.fetch("fixture_post_pr").fail_policy).to eq(:advance)
  end

  it "does not require the post-implementation contract to repeat the step kind fail policy" do
    expect(Step::Kind.fetch("fixture_post_implementation").fail_policy).to eq(:advance)
    expect(described_class.post_implementation(job: enabled_job)).to eq([ "fixture_post_implementation" ])
  end

  it "rejects a post-PR contribution that omits its required fail policy" do
    allow(WorkflowCompositionFixture::PostPr).to receive(:post_pr).and_return(
      [ { step_kind: "fixture_post_pr", order: 30, enabled_for: ->(_job) { true } } ]
    )

    expect(described_class.post_pr(job: enabled_job)).to be_empty
    expect(Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "workflow_composition_fixture" }.validation_errors)
      .to contain_exactly(/key not found: :fail_policy/)
  end

  it "records callable validation errors without wrapping them as unknown step kinds" do
    allow(WorkflowCompositionFixture::Judge).to receive(:judges).and_return(
      [ { step_kind: "fixture_judge", trigger_kinds: %w[initial], rounds_for: 2 } ]
    )

    expect(described_class.judges(job: enabled_job, trigger_kind: "initial", agent_step: :implement)).to be_empty
    expect(Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "workflow_composition_fixture" }.validation_errors)
      .to contain_exactly("workflow_composition_fixture judge rounds_for must be callable")
  end

  it "orders multiple contributions by declared order" do
    later = Class.new do
      def self.post_implementation
        [ { step_kind: "fixture_post_implementation_later", order: 50, enabled_for: ->(_job) { true } } ]
      end
    end
    Syrus::PluginRegistry.register(
      name: "workflow_composition_later_fixture", version: "1.0.0",
      provides: { "workflow:post_implementation" => later }
    )

    expect(described_class.post_implementation(job: enabled_job)).to eq(
      %w[fixture_post_implementation fixture_post_implementation_later]
    )
  end
end
