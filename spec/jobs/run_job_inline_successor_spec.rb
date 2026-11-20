require "rails_helper"

# While a RunJob drives a Workflow, Runs the dispatcher creates for that
# Workflow skip SolidQueue: the driver is expected to pick its successor up
# inline. It only ever picks one -- the first queued Run found by walking
# next_step pointers from the Step it just ran. Every other Run created in
# that window had no queue job at all until the reconciler re-enqueued it,
# about two minutes later: parallel graders, panel members, repair Steps
# inserted off the pointer chain. Production re-enqueued ~15 a day.
RSpec.describe RunJob, "handing back Runs it will not drive inline" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.create!(kind: "grader", position: 90, state: "running", started_at: 1.minute.ago) }
  let(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
                      state: "running", started_at: 1.minute.ago)
  end

  before do
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    run # created (and enqueued) outside any RunJob; not what is under test
    clear_enqueued_jobs
  end

  def off_chain_run(position)
    off_step = workflow.steps.create!(kind: "grader", position: position, state: "queued")
    off_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
  end

  it "enqueues every Run created during its step that it does not pick up" do
    created = []
    allow_any_instance_of(described_class).to receive(:perform_step) do
      created << off_chain_run(91) << off_chain_run(92)
    end
    allow_any_instance_of(described_class).to receive(:next_inline_run).and_return(nil)

    described_class.perform_now(run.id)

    enqueued_ids = enqueued_jobs.select { |entry| entry[:job] == RunJob }.map { |entry| entry[:args].first }
    expect(enqueued_ids).to match_array(created.map(&:id))
  end

  it "enqueues nothing extra for the successor it does drive" do
    successor = nil
    calls = 0
    allow_any_instance_of(described_class).to receive(:perform_step) do
      calls += 1
      successor ||= off_chain_run(91) if calls == 1
    end
    allow_any_instance_of(described_class).to receive(:next_inline_run) do
      calls == 1 ? successor : nil
    end

    described_class.perform_now(run.id)

    expect(enqueued_jobs.select { |entry| entry[:job] == RunJob }).to be_empty
  end

  it "hands a successor straight back when it yields on SIGTERM" do
    successor = nil
    allow_any_instance_of(described_class).to receive(:perform_step) do |run_job|
      successor = off_chain_run(91)
      run_job.instance_variable_set(:@shutdown_requested, true)
    end
    allow_any_instance_of(described_class).to receive(:next_inline_run) { successor }

    described_class.perform_now(run.id)

    expect(enqueued_jobs.select { |entry| entry[:job] == RunJob }.map { |entry| entry[:args].first }).to eq([ successor.id ])
  end
end
