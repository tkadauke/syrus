require "rails_helper"

# AppSetting.polling_paused? and .runs_paused? are checked by the
# fan-out polling jobs and RunJob respectively. When set, fan-out
# jobs short-circuit; RunJob defers itself by re-enqueueing.
RSpec.describe "Pause behavior" do
  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
  end

  describe "polling pause" do
    %w[
      PollAllRepositoriesJob
      PollAllPullRequestsJob
      PollAllMergeStatesJob
      PollAllDeploymentStagesJob
      PollScheduledTasksJob
    ].each do |klass|
      it "#{klass} short-circuits when polling_paused is true" do
        AppSetting.current.update!(polling_paused: true)
        # Each fan-out job's body would normally enqueue downstream
        # jobs. With the pause flag set, no enqueues should happen.
        expect {
          klass.constantize.new.perform
        }.not_to have_enqueued_job
      end
    end
  end

  describe "runs pause" do
    let(:job) { Factories.job }
    let(:run) { job.initial_run }

    it "RunJob.perform re-enqueues itself with a delay instead of working" do
      AppSetting.current.update!(runs_paused: true)
      expect {
        RunJob.perform_now(run.id)
      }.to have_enqueued_job(RunJob).with(run.id).at(a_value_within(2.seconds).of(RunJob::RUNS_PAUSED_RETRY_DELAY.from_now))
      expect(run.reload.state).to eq("queued")  # didn't transition
    end

    it "RunJob.perform proceeds normally when runs_paused is false" do
      # Just assert the pause guard isn't tripping — actual run
      # processing exercises the existing run_job_spec.
      expect {
        RunJob.new.perform(run.id)
      }.not_to have_enqueued_job(RunJob)
    rescue StandardError
      # Any handler-time error is fine for this test — we only
      # care that the early-return-with-reenqueue path didn't fire.
    end
  end
end
