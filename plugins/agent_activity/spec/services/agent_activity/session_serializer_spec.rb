require "rails_helper"

RSpec.describe AgentActivity::SessionSerializer do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  it "serializes role/label structurally from Step::Kind, not from transcript text" do
    job = Factories.job_with_run(
      repository: repository,
      issue_title: "Fix the aqueducts",
      step_attrs: { kind: "adversarial_review" },
      run_attrs: { state: "running", agent_provider: "claude", started_at: 5.minutes.ago }
    )
    run = job.runs.last

    payload = described_class.call(run, transcript_path: "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts")

    expect(payload).to include(
      id: run.id,
      slug: "RUN-#{run.id}",
      state: "running",
      step_kind: "adversarial_review",
      role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER,
      role_label: Step::Kind.label_for("adversarial_review"),
      agent_provider: "claude",
      transcript_path: "/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts"
    )
    expect(payload[:job]).to include(id: job.id, title: "Fix the aqueducts")
    expect(payload[:repository]).to eq(id: repository.id, slug: "acme/widgets")
  end

  it "computes duration from started_at to finished_at, or to now while still running" do
    job = Factories.job_with_run(
      repository: repository,
      run_attrs: { state: "succeeded", started_at: 10.minutes.ago, finished_at: 4.minutes.ago }
    )
    run = job.runs.last

    payload = described_class.call(run, transcript_path: "x")

    expect(payload[:duration_seconds]).to be_within(2).of(6.minutes.to_i)
  end

  it "surfaces the submitted outcome text and verdict" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "visual_review", iteration: 1 },
      run_attrs: { state: "succeeded" }
    )
    run = job.runs.last
    run.workflow.set_artifact!("visual_review_iterations", [ { "iteration" => 1, "critique" => "Layout shifted.", "verdict" => "needs_work" } ])

    payload = described_class.call(run, transcript_path: "x")

    expect(payload[:outcome_summary]).to eq("Layout shifted.")
    expect(payload[:outcome_verdict]).to eq("needs_work")
  end
end
