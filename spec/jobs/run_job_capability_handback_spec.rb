require "rails_helper"

# A worker hands back a Run whose placement it does not satisfy. When no live
# worker satisfies it either -- the last capable one failed an environment
# smoke check after the Run was enqueued -- the hand-back re-enqueued it onto
# the same queue every five seconds: the same worker claimed it and handed it
# back indefinitely, the Run stayed queued with no blocked reason, and nothing
# surfaced the wait (F150). The first enqueue already blocks such a Run with
# a named reason and a recheck; the hand-back must do the same.
RSpec.describe RunJob, "handing back a Run no live worker satisfies" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:run) { workflow.first_step.runs.first }
  let(:blocked) do
    RunQueueResolver::Decision.new(
      queue_name: "runs_macos", requirements: { "os" => [ "macos" ] }, sticky_resume: false,
      blocked_reason: RunQueueResolver::ENVIRONMENT_CHECK_BLOCKED_REASON,
      details: { "live_workers" => [ { "hostname" => "mac-mini-a", "environment_check_failures" => { "xcode" => "missing" } } ] }
    )
  end

  before do
    allow(RunQueueResolver).to receive(:locally_satisfied?).and_return(false)
    allow(RunQueueResolver).to receive(:resolve).and_return(blocked)
  end

  it "blocks the Run with the resolver's reason instead of re-enqueueing it" do
    job_instance = RunJob.new(run.id)
    job_instance.instance_variable_set(:@run, run)
    job_instance.instance_variable_set(:@step, run.step)
    allow(job_instance).to receive(:compute_run?).and_return(true)
    clear_enqueued_jobs

    expect(job_instance.send(:hand_back_incapable_run?)).to be(true)

    expect(enqueued_jobs.select { |entry| entry[:job] == RunJob }).to be_empty
    expect(run.reload).to be_queued
    expect(workflow.reload.artifact("run_queue_blocked")).to include("reason" => RunQueueResolver::ENVIRONMENT_CHECK_BLOCKED_REASON)
  end
end
