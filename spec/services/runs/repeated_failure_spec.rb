require "rails_helper"

# Regression: a deterministic timeout was rerun in place three times per
# workflow attempt and retried across four attempts -- twelve identical
# failures -- because the dispatcher's in-place reruns and the auto-retry
# ladder each spent a budget of their own. They now share one per
# (Job, step kind, fingerprint).
RSpec.describe Runs::RepeatedFailure do
  let(:job) { Factories.job_record(state: "running") }

  def workflow
    Workflow.create!(job: job, user: job.user, trigger_kind: "initial", state: "failed", finished_at: Time.current)
  end

  def step_in(workflow, kind: "implement")
    Step.create!(workflow: workflow, kind: kind, position: 0, state: "failed")
  end

  def failed_run(step, message: "execution expired", error_class: "Timeout::Error", classification: "timeout")
    run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "skipped")
    run.update_columns(state: "failed", finished_at: Time.current)
    RunDiagnostic.create!(run: run, error_class: error_class, error_message: message)
    RunFailureClassification.find_or_initialize_by(run_id: run.id)
      .update!(classification: classification, retryable: true, confidence: 0.9, classified_at: Time.current)
    run.reload
  end

  describe ".stop_in_place?" do
    it "reruns a first failure in place" do
      run = failed_run(step_in(workflow))

      expect(described_class.stop_in_place?(run)).to be(false)
    end

    it "stops once a rerun failed exactly like the run before it" do
      step = step_in(workflow)
      failed_run(step, message: "execution expired after 600 seconds")
      rerun = failed_run(step, message: "execution expired after 601 seconds")

      expect(described_class.repeats_previous_run?(rerun)).to be(true)
      expect(described_class.stop_in_place?(rerun)).to be(true)
    end

    it "keeps rerunning when the rerun failed differently" do
      step = step_in(workflow)
      failed_run(step, message: "execution expired")
      rerun = failed_run(step, message: "connection reset by peer", error_class: "Errno::ECONNRESET")

      expect(described_class.stop_in_place?(rerun)).to be(false)
    end

    it "never stops a lost worker, whose retry runs somewhere else" do
      step = step_in(workflow)
      failed_run(step, message: "worker died", classification: "worker_died")
      rerun = failed_run(step, message: "worker died", classification: "worker_died")

      expect(described_class.stop_in_place?(rerun)).to be(false)
    end
  end

  describe ".budget_exhausted?" do
    it "counts identical failures of one step kind across the Job's workflows" do
      runs = 4.times.map { failed_run(step_in(workflow)) }

      expect(described_class.identical_failures(runs.last)).to eq(4)
      expect(described_class.budget_exhausted?(runs[2])).to be(true)
      expect(described_class.budget_exhausted?(runs.last)).to be(true)
    end

    it "is not exhausted below the shared limit" do
      runs = (described_class::MAX_IDENTICAL_FAILURES - 1).times.map { failed_run(step_in(workflow)) }

      expect(described_class.budget_exhausted?(runs.last)).to be(false)
    end

    it "keeps other step kinds and other failures apart" do
      2.times { failed_run(step_in(workflow, kind: "prepare")) }
      failed_run(step_in(workflow), message: "something else", error_class: "RuntimeError")
      run = failed_run(step_in(workflow))

      expect(described_class.identical_failures(run)).to eq(1)
    end

    it "does not count failures from before the Job was reopened" do
      3.times { failed_run(step_in(workflow)) }
      job.update_columns(reopened_at: 1.second.from_now)
      travel 2.seconds do
        run = failed_run(step_in(workflow))

        expect(described_class.identical_failures(run)).to eq(1)
      end
    end

    it "exempts classifications that wait on a reset" do
      runs = 5.times.map { failed_run(step_in(workflow), message: "rate limit exceeded", classification: "rate_limited") }

      expect(described_class.budget_exhausted?(runs.last)).to be(false)
    end
  end
end
