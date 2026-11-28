require "rails_helper"

# A production grader fan-out Run was executed twice at once. Two RunJobs of
# one Job (two Runs of its prepare Step) each succeeded the Step -- the second
# from a stale copy -- so the chain advanced twice, and both then picked up
# the newest queued fan-out Run inline. Each claimed it queued -> running:
# under MySQL's REPEATABLE READ the second claim's plain re-read answered from
# a snapshot taken before the first claim committed. The two executions raced
# on the Run's log sequence and one failed the Step.
#
# SQLite has no such snapshot, so these examples stage the stale read by
# making the in-memory record's reload a no-op while the row holds the
# committed truth.
RSpec.describe RunJob, "duplicate execution of one Run" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }

  before do
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
  end

  def run_job_for(run, step: run.step)
    described_class.new.tap do |run_job|
      run_job.instance_variable_set(:@run, run)
      run_job.instance_variable_set(:@step, step)
      run_job.instance_variable_set(:@workflow, workflow)
      run_job.instance_variable_set(:@job, job)
    end
  end

  def pin_stale_read(record)
    allow(record).to receive(:reload).and_return(record)
  end

  describe "claiming a queued Run" do
    let(:step) { workflow.steps.create!(kind: "grader_fanout", position: 99, state: "queued") }
    let(:run) do
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    end

    it "lets only one of two performs that both read the Run as queued start it" do
      stale_copy = Run.find(run.id)
      winner = run_job_for(Run.find(run.id), step: Step.find(step.id))
      expect(winner.send(:acquire_run_execution!)).to be(true)
      expect(run.reload).to have_attributes(state: "running", execution_attempt: 1)

      # The second perform read the Run before the first claim committed.
      pin_stale_read(stale_copy)
      expect(stale_copy).to be_queued
      loser = run_job_for(stale_copy, step: Step.find(step.id))
      allow(loser).to receive(:record_run_started_activity!)

      expect(loser.send(:acquire_run_execution!)).to be(false)

      expect(loser).not_to have_received(:record_run_started_activity!)
      expect(run.reload).to have_attributes(state: "running", execution_attempt: 1)
      starts = StateTransition.where(subject_type: "Run", subject_id: run.id, event_name: "start")
      expect(starts.count).to eq(1)
    end
  end

  describe "a second delivery of a Run another perform is executing" do
    let(:step) { workflow.steps.create!(kind: "grader_fanout", position: 99, state: "running", started_at: 1.minute.ago) }
    let(:run) do
      step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
        state: "running", started_at: 1.minute.ago, last_heartbeat_at: 5.seconds.ago, execution_attempt: 1
      )
    end

    it "exits without running the handler, logging, or touching the Run" do
      allow(Steps).to receive(:handler_for).and_call_original
      before_state = run.reload.attributes.slice("state", "execution_attempt", "started_at", "finished_at")

      described_class.perform_now(run.id)

      expect(Steps).not_to have_received(:handler_for)
      expect(run.job_logs.count).to eq(0)
      expect(run.reload.attributes.slice("state", "execution_attempt", "started_at", "finished_at")).to eq(before_state)
      expect(step.reload).to be_running
    end
  end

  describe "two Runs of one Step succeeding together" do
    let(:step) { workflow.steps.create!(kind: "prepare", position: 99, state: "running", started_at: 3.minutes.ago) }
    let(:first_run) do
      step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
        state: "running", started_at: 3.minutes.ago
      )
    end
    let(:second_run) do
      step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
        state: "running", started_at: 2.minutes.ago
      )
    end

    before do
      # Advancing the chain is observed, not exercised.
      allow(Steps::LifecyclePropagation).to receive(:succeeded!)
    end

    it "advances the chain once, not once per Run" do
      stale_step = Step.find(step.id)
      second = run_job_for(second_run, step: stale_step)
      run_job_for(first_run, step: Step.find(step.id)).send(:record_successful_step!)
      expect(step.reload).to be_succeeded

      # The second perform read the Step as running before the first
      # success committed.
      pin_stale_read(stale_step)
      expect(stale_step).to be_running
      second.send(:record_successful_step!)

      expect(second_run.reload).to be_succeeded
      expect(Steps::LifecyclePropagation).to have_received(:succeeded!).once
      successes = StateTransition.where(subject_type: "Step", subject_id: step.id, event_name: "succeed")
      expect(successes.count).to eq(1)
    end
  end

  describe "picking up an inline successor" do
    let(:current_step) { workflow.steps.create!(kind: "prepare", position: 98, state: "succeeded") }
    let(:successor_step) { workflow.steps.create!(kind: "grader_fanout", position: 99) }
    let(:current_run) do
      current_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "succeeded")
    end

    before do
      current_step.update!(next_step_id: successor_step.id)
    end

    around do |example|
      prior = Thread.current[Run::INLINE_HELD_RUN_IDS]
      example.run
    ensure
      Thread.current[Run::INLINE_HELD_RUN_IDS] = prior
    end

    it "takes a queued successor this perform kept off the queue" do
      successor = successor_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      Thread.current[Run::INLINE_HELD_RUN_IDS] = [ successor.id ]

      expect(run_job_for(current_run, step: current_step).send(:next_inline_run)).to eq(successor)
    end

    it "leaves a queued successor it does not hold to its own queue entry or holder" do
      held = successor_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      # The newest queued Run of the Step, held by another perform of the Job.
      foreign = successor_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      Thread.current[Run::INLINE_HELD_RUN_IDS] = [ held.id ]
      clear_enqueued_jobs

      expect(run_job_for(current_run, step: current_step).send(:next_inline_run)).to eq(held)

      Thread.current[Run::INLINE_HELD_RUN_IDS] = []
      expect(run_job_for(current_run, step: current_step).send(:next_inline_run)).to be_nil
      expect(foreign.reload).to be_queued
      expect(enqueued_jobs.select { |entry| entry[:job] == RunJob }).to be_empty
    end
  end
end
