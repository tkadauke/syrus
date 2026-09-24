require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Investigate do
  let(:job) do
    Factories.job(
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigation: what's slow?",
      issue_body: "Investigate: why does /dashboard feel slow?",
      investigation: true
    )
  end
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.find_by(kind: "investigate") }
  let(:run)      do
    step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-investigate") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
  end

  it "dispatches into the investigation trigger_kind's prepare → investigate → submit_report chain" do
    expect(workflow.trigger_kind).to eq("investigation")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[prepare investigate submit_report]
    )
  end

  it "renders the operator's investigation prompt with the standard safety/context blocks" do
    handler.call

    prompt = run.reload.prompt
    expect(prompt).to include("Investigate: why does /dashboard feel slow?")
    expect(prompt).to include("investigation-only Job")
  end

  it "includes the phased-execution note telling the agent not to call submit_report here" do
    handler.call

    expect(run.reload.prompt).to include("Phased execution note: you're running the **investigate** step")
    expect(run.reload.prompt).to include("DO NOT call `submit_report`")
  end

  it "does not commit changes, capture a diff, or ever call raise_no_changes_produced!" do
    expect(handler).not_to receive(:commit_agent_changes)
    expect(handler).not_to receive(:diff_against_default)
    expect(handler).not_to receive(:raise_no_changes_produced!)

    expect { handler.call }.not_to raise_error
    expect(run.reload.agent_diff).to be_nil
  end

  it "does not re-render the prompt when one is already present" do
    run.update!(prompt: "already set")

    handler.call

    expect(run.reload.prompt).to eq("already set")
  end

  it "invokes the agent with the persisted prompt" do
    expect(handler).to receive(:run_agent).with(prompt: an_instance_of(String))

    handler.call
  end
end
