require "rails_helper"

# Run execution is fenced by an attempt counter (decided: attempt fencing).
# Recovery requeues a Run whose worker looks dead; if that worker was only
# stalled -- a long GC, a network partition, a laptop asleep -- it resumed and
# carried on (commit, push, call GitHub), because ensure_run_still_active!
# only refused terminal records and a requeued Run is queued, not terminal.
RSpec.describe "Run execution fencing" do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.create!(kind: "summarize", position: 99, state: "running", started_at: 1.minute.ago) }
  let(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
                      state: "running", started_at: 1.minute.ago, execution_attempt: 1)
  end
  let(:handler) { Steps::Base.new(run) }

  before { workflow.update_columns(state: "running", started_at: 2.minutes.ago) }

  def checkpoint!
    handler.send(:ensure_run_still_active!, "push")
  end

  it "lets the executor that holds the current attempt continue" do
    run.claimed_execution_attempt = 1

    expect { checkpoint! }.not_to raise_error
  end

  it "stops a stalled executor once its Run was requeued" do
    run.claimed_execution_attempt = 1
    Run.where(id: run.id).update_all(state: "queued")

    expect { checkpoint! }.to raise_error(Steps::Base::RunEndedExternally, /requeued/)
  end

  it "stops a stalled executor once another worker claimed its Run again" do
    run.claimed_execution_attempt = 1
    Run.where(id: run.id).update_all(execution_attempt: 2)

    expect { checkpoint! }.to raise_error(Steps::Base::RunEndedExternally, /claimed again/)
  end

  it "leaves a Run this process never claimed to the terminal check alone" do
    Run.where(id: run.id).update_all(state: "queued")

    expect { checkpoint! }.not_to raise_error
  end

  it "increments the attempt and records what this executor claimed" do
    queued = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    queued.update_columns(execution_attempt: 3)
    step.update_columns(state: "queued", started_at: nil)
    run_job = RunJob.new
    run_job.instance_variable_set(:@run, queued)

    run_job.send(:acquire_run_execution!)

    expect(queued.reload).to have_attributes(state: "running", execution_attempt: 4)
    expect(run_job.instance_variable_get(:@run).claimed_execution_attempt).to eq(4)
  end
end
