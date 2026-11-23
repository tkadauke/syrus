require "rails_helper"

RSpec.describe ReviewPlanning::Tools::SubmitReviewPlanTool do
  let(:job) { Factories.job }
  let(:step) { Step.create!(workflow: job.workflows.last, kind: "review_plan", position: 100) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }

  def call(items: [ { file: "app/models/user.rb", line: 10, note: "Tricky retry logic." } ], summary: nil)
    described_class.call(items: items, summary: summary, server_context: { run: run })
  end

  it "accepts a run_id-only sidecar context" do
    described_class.call(
      items: [ { file: "app.rb", line: 1, note: "Check this." } ],
      server_context: { run_id: run.id }
    )

    expect(run.workflow.reload.artifact("review_plan")).to include(
      "items" => [ { "file" => "app.rb", "line" => 1, "note" => "Check this." } ]
    )
  end

  it "persists items and summary on the workflow artifact" do
    call(
      items: [
        { file: "app/models/user.rb", line: 10, note: "Tricky retry logic." },
        { file: "app/services/foo.rb", note: "No line anchor." }
      ],
      summary: "Overall looks solid."
    )

    expect(run.workflow.reload.artifact("review_plan")).to eq(
      "items" => [
        { "file" => "app/models/user.rb", "line" => 10, "note" => "Tricky retry logic." },
        { "file" => "app/services/foo.rb", "line" => nil, "note" => "No line anchor." }
      ],
      "summary" => "Overall looks solid."
    )
  end

  it "accepts an empty items list when nothing stands out" do
    call(items: [])

    expect(run.workflow.reload.artifact("review_plan")).to eq(
      "items" => [],
      "summary" => nil
    )
  end

  it "drops items missing a file or note" do
    call(items: [
      { file: "", note: "Missing file." },
      { file: "app.rb", note: "" },
      { file: "app.rb", note: "Kept." }
    ])

    expect(run.workflow.reload.artifact("review_plan")["items"]).to eq(
      [ { "file" => "app.rb", "line" => nil, "note" => "Kept." } ]
    )
  end

  it "normalizes binary-tagged UTF-8" do
    call(items: [ { file: "app.rb".b, note: "Review ● output.".b } ], summary: "Note ●.".b)

    artifact = run.workflow.reload.artifact("review_plan")
    expect(artifact["items"].first["note"]).to eq("Review ● output.")
    expect(artifact["items"].first["note"].encoding).to eq(Encoding::UTF_8)
    expect(artifact["summary"]).to eq("Note ●.")
  end

  it "rejects a non-array items value" do
    response = described_class.call(items: "not an array", server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("items must be an array")
    expect(run.workflow.reload.artifact("review_plan")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_review_plan received: 1 item(s)")
  end

  it "exposes the expected tool name and required schema" do
    expect(described_class.tool_name).to eq("submit_review_plan")
    expect(described_class.input_schema_value.to_h[:required]).to eq(%w[items])
  end

  it "refuses to run outside the review_plan step" do
    other = Run.create!(job: job, step: Step.create!(workflow: job.workflows.last, kind: "summarize", position: 101), trigger_kind: "initial")

    response = described_class.call(items: [], server_context: { run: other })

    expect(response).to be_error
    expect(other.workflow.reload.artifact("review_plan")).to be_nil
  end
end
