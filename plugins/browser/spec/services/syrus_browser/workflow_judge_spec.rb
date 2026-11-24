require "rails_helper"

RSpec.describe SyrusBrowser::WorkflowJudge do
  let(:job) { Factories.job }

  it "keeps configured visual review in the judge position and preserves its round count" do
    allow(SyrusBrowser::RepoVisualReviewPlan).to receive(:for_job).with(job).and_return(
      SyrusBrowser::RepoVisualReviewPlan::Result.new(enabled: true, rounds: 3, source: ".syrus.yml", note: nil)
    )

    loops = Workflows::CompositionAnchors.judges(job: job, trigger_kind: "initial", agent_step: "implement")

    expect(loops.map(&:to_chain_template)).to eq([
      { "type" => "loop", "max_iterations" => 3, "steps" => %w[implement visual_review] }
    ])
  end

  it "contributes no loop when browser is disabled" do
    PluginRecord.find_or_create_by!(name: "browser").update!(enabled: false)

    expect {
      expect(Workflows::CompositionAnchors.judges(job: job, trigger_kind: "initial", agent_step: "implement")).to be_empty
    }.not_to raise_error
  ensure
    PluginRecord.find_by(name: "browser")&.update!(enabled: true)
  end

  it "does not contribute to external PR feedback workflows" do
    allow(SyrusBrowser::RepoVisualReviewPlan).to receive(:for_job).and_return(
      SyrusBrowser::RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
    )

    expect(
      Workflows::CompositionAnchors.judges(
        job:, trigger_kind: "external_pr_feedback", agent_step: "respond"
      )
    ).to be_empty
  end

  it "keeps visual review outside the required immutable-HEAD review registry" do
    entry = Step::Kind.fetch("visual_review")

    expect(entry.review_gate).to eq(
      artifact_key: "visual_review_iterations",
      exit_verdicts: %w[approved skipped],
      cancellation_reason: "visual_review_approved"
    )
    expect(Workflows::ReviewGateRegistry.definitions.map(&:step_kind)).not_to include("visual_review")
  end
end
