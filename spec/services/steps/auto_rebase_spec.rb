require "rails_helper"

RSpec.describe Steps::AutoRebase do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Rebase.instantiate(job: job) }
  let(:auto_rebase_step) { workflow.steps.find_by!(kind: "auto_rebase") }
  let(:agent_rebase_step) { workflow.steps.find_by!(kind: "agent_rebase") }
  let(:force_push_step) { workflow.steps.find_by!(kind: "force_push") }
  let(:run) { Run.create!(job: job, step: auto_rebase_step, trigger_kind: "rebase") }
  let(:service) { instance_double(::AutoRebase) }

  before do
    allow(::AutoRebase).to receive(:new).with(job).and_return(service)
  end

  it "skips only the agent rebase step after a clean deterministic rebase" do
    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(true, "rebased", "advanced abc1234 -> def5678"))

    described_class.new(run).call

    expect(agent_rebase_step.reload.state).to eq("cancelled")
    expect(force_push_step.reload.state).to eq("queued")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("auto_rebase already succeeded")
  end

  it "leaves the agent rebase step queued and records the reason when deterministic rebase conflicts" do
    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(false, "conflict", nil))

    described_class.new(run).call

    expect(agent_rebase_step.reload.state).to eq("queued")
    expect(force_push_step.reload.state).to eq("queued")
    expect(workflow.reload.artifact("auto_rebase_reason")).to eq("conflict")
  end

  it "does not rewrite a terminal agent rebase step on a later clean result" do
    agent_rebase_step.start!
    agent_rebase_step.fail!
    agent_rebase_step.save!

    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(true, "rebased", "no-op"))

    described_class.new(run).call

    expect(agent_rebase_step.reload.state).to eq("failed")
  end
end
