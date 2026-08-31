require "rails_helper"

RSpec.describe Workflows::VisualDiff do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented") }

  before { clear_enqueued_jobs }

  it "uses the visual_diff trigger kind" do
    expect(described_class.trigger_kind).to eq("visual_diff")
  end

  it "runs prepare then the visual_diff step" do
    expect(described_class.steps_for(job)).to eq(%w[prepare visual_diff])
  end

  it "dispatches at low queue priority" do
    workflow = described_class.instantiate(job: job)

    expect(described_class.solid_queue_priority(workflow)).to eq(Job::PRIORITY_TO_SQ["low"])
    expect(workflow.solid_queue_priority).to eq(Job::PRIORITY_TO_SQ["low"])
  end

  it "keeps deferred admission rechecks at low queue priority" do
    workflow = described_class.instantiate(job: job)
    gate_result = WorkUnits::GateResult.block(reason: WorkUnits::Gates::ActiveWorkLock::REASON)

    WorkUnits::Launcher.schedule_blocked_recheck!(workflow, gate_result)

    expect(enqueued_jobs.last[:job]).to eq(WorkflowPhaseAdmissionJob)
    expect(enqueued_jobs.last[:args]).to eq([ workflow.id ])
    expect(enqueued_jobs.last[:priority]).to eq(Job::PRIORITY_TO_SQ["low"])
  end
end
