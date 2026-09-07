require "rails_helper"

RSpec.describe AgentActivity::OutcomeSummary do
  let(:repository) { Factories.repository }

  it "reads the summarize step's own agent_summary" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "summarize" },
      run_attrs: { state: "succeeded", agent_summary: "Added the greeting helper." }
    )
    run = job.runs.last

    result = described_class.for(run)

    expect(result).to eq(text: "Added the greeting helper.", verdict: nil)
  end

  it "matches an adversarial_review Run to its own iteration's critique/verdict, not another iteration's" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "adversarial_review", iteration: 2 },
      run_attrs: { state: "succeeded" }
    )
    run = job.runs.last
    workflow = run.workflow
    workflow.set_artifact!("adversarial_review_iterations", [
      { "iteration" => 1, "critique" => "First pass looked fine.", "verdict" => "approved" },
      { "iteration" => 2, "critique" => "Missing a test for the edge case.", "verdict" => "needs_work" }
    ])

    result = described_class.for(run)

    expect(result).to eq(text: "Missing a test for the edge case.", verdict: "needs_work")
  end

  it "matches a visual_review Run to its own iteration" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "visual_review", iteration: 1 },
      run_attrs: { state: "succeeded" }
    )
    run = job.runs.last
    run.workflow.set_artifact!("visual_review_iterations", [
      { "iteration" => 1, "critique" => "Looks correct.", "verdict" => "approved" }
    ])

    result = described_class.for(run)

    expect(result).to eq(text: "Looks correct.", verdict: "approved")
  end

  it "falls back to agent_summary when no matching review iteration was recorded yet" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "adversarial_review" },
      run_attrs: { state: "running", agent_summary: nil }
    )
    run = job.runs.last

    result = described_class.for(run)

    expect(result).to eq(text: nil, verdict: nil)
  end

  it "returns a blank summary for a plain agentic step that submitted nothing" do
    job = Factories.job_with_run(
      repository: repository,
      step_attrs: { kind: "implement" },
      run_attrs: { state: "running", agent_summary: nil }
    )
    run = job.runs.last

    expect(described_class.for(run)).to eq(text: nil, verdict: nil)
  end
end
