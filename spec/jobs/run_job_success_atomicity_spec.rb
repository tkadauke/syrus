require "rails_helper"

# A Run's success and its Step's success are one fact. Committed separately,
# the Run's after-commit propagation ran (and the reconciler could look) while
# the Step was still running with every Run terminal -- the state
# `running_step_with_terminal_runs` flags. In production the reconciler
# planned a repair for it on almost every pass and then skipped it ("Step is
# succeeded, not active") once the second commit landed.
RSpec.describe RunJob, "recording a successful step" do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.create!(kind: "grader", position: 99, state: "running", started_at: 1.minute.ago) }
  let(:run) do
    step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "running", started_at: 1.minute.ago
    )
  end

  before do
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    # Advancing the chain is not under test here.
    allow(Steps::LifecyclePropagation).to receive(:succeeded!)
  end

  it "commits the Run and its Step together, before either one's propagation runs" do
    observed = []
    allow(Runs::LifecyclePropagation).to receive(:succeeded!).and_wrap_original do |original, propagated_run|
      observed << Step.where(id: propagated_run.step_id).pick(:state)
      original.call(propagated_run)
    end

    run_job = described_class.new
    run_job.instance_variable_set(:@run, run)
    run_job.instance_variable_set(:@step, step)
    run_job.instance_variable_set(:@workflow, workflow)
    run_job.send(:record_successful_step!)

    expect(run.reload).to be_succeeded
    expect(step.reload).to be_succeeded
    expect(observed).to eq([ "succeeded" ])
    # Both commit callbacks still fire once: a no-op save in the same
    # transaction would clear saved_changes and silently stop the chain.
    expect(Steps::LifecyclePropagation).to have_received(:succeeded!).once
  end

  # record_successful_step! reloads and checks the states before it takes the
  # Lineage lock; a cancel can commit in between. The success must then not
  # overwrite it from the pre-lock attributes.
  it "keeps a cancel that committed before the success took its lock" do
    allow(Lineage).to receive(:lock!).and_wrap_original do |original, record|
      result = original.call(record)
      if record.is_a?(Run)
        Run.where(id: run.id).update_all(state: "cancelled", finished_at: Time.current)
        Step.where(id: step.id).update_all(state: "cancelled", finished_at: Time.current)
      end
      result
    end

    run_job = described_class.new
    run_job.instance_variable_set(:@run, run)
    run_job.instance_variable_set(:@step, step)
    run_job.instance_variable_set(:@workflow, workflow)
    run_job.send(:record_successful_step!)

    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(Steps::LifecyclePropagation).not_to have_received(:succeeded!)
  end

  it "clears a stale worker_died outcome when the Run succeeds" do
    run.update_columns(agent_outcome: "worker_died")

    run_job = described_class.new
    run_job.instance_variable_set(:@run, run)
    run_job.instance_variable_set(:@step, step)
    run_job.instance_variable_set(:@workflow, workflow)
    run_job.send(:record_successful_step!)

    expect(run.reload).to have_attributes(state: "succeeded", agent_outcome: nil)
  end
end
