require "rails_helper"

RSpec.describe Steps::PostImplementationReview do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.latest_workflow }
  let(:step) { Step.create!(workflow: workflow, kind: "post_implementation_review", position: 100) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind) }
  let(:handler) { described_class.new(run) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/workspace")) }

  around do |example|
    snapshot = Syrus::PluginRegistry.boot_snapshot
    example.run
  ensure
    Syrus::PluginRegistry.restore(snapshot) if snapshot
  end

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
  end

  it "skips without invoking an agent when no enabled provider requests review" do
    expect(handler).not_to receive(:run_agent)

    handler.call

    expect(job.job_logs.last.chunk).to include("no enabled providers requested review notes")
  end

  it "invokes the agent with provider prompt sections and required tools" do
    provider = Class.new do
      include Syrus::Plugin::PostImplementationReviewProvider

      def self.review_needed?(job:, trigger_kind:)
        trigger_kind == "initial"
      end

      def self.prompt_sections(job:, workflow:, run:)
        [ "Provider review prompt for #{job.repository.slug}." ]
      end

      def self.required_mcp_tools(job:, workflow:, run:)
        [ "submit_review_notes" ]
      end
    end
    Syrus::PluginRegistry.register(
      name: "post_implementation_review_spec_provider",
      version: "1.0.0",
      provides: { post_implementation_review_provider: provider }
    )

    expect(handler).to receive(:run_agent) do |prompt:, max_turns:, required_mcp_tools:, enforce_required_mcp_tools:, **|
      expect(prompt).to include("Provider review prompt")
      expect(max_turns).to eq(described_class::TURN_BUDGET)
      expect(required_mcp_tools).to eq([ "submit_review_notes" ])
      expect(enforce_required_mcp_tools).to be(true)
    end

    handler.call

    expect(run.reload.prompt).to include("Provider review prompt")
  end

  it "fails clearly when a required review-note tool is missing or uncalled" do
    provider = Class.new do
      include Syrus::Plugin::PostImplementationReviewProvider

      def self.review_needed?(job:, trigger_kind:) = true
      def self.required_mcp_tools(job:, workflow:, run:) = [ "submit_review_notes" ]
    end
    Syrus::PluginRegistry.register(
      name: "post_implementation_review_failure_spec_provider",
      version: "1.0.0",
      provides: { post_implementation_review_provider: provider }
    )

    allow(handler).to receive(:run_agent).and_raise(Steps::Base::StepFailed, "agent didn't call submit_review_notes")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, "agent didn't call submit_review_notes")
  end
end
