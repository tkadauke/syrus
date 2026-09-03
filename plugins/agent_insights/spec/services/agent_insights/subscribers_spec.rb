require "rails_helper"

# The sweep cadence: a repository gets a new insight sweep once enough coding
# Jobs have closed since the last one. This was an Active Record callback on
# core's Job; it is a job.closed domain-event subscriber now.
RSpec.describe AgentInsights::Subscribers do
  include ActiveJob::TestHelper

  let(:repository) { Factories.repository }
  let(:user) { repository.user }

  before do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)
    allow(AgentInsights::Scheduler).to receive(:enqueue_if_idle!)
  end

  def enable_insight_config(max:)
    AgentInsights::ScheduleConfig.create!(
      repository: repository,
      enabled: true,
      min_jobs_since_last_run: 1,
      max_jobs_since_last_run: max
    )
  end

  # job.closed is delivered async, one DomainEventJob per subscriber, so the
  # example has to drain the queue to see the subscriber actually run.
  def close_a_job!(**attrs)
    job = Factories.job_record(user: user, repository: repository, state: "queued", **attrs)
    perform_enqueued_jobs(only: DomainEventJob) { job.close! }
    job
  end

  it "does not sweep when the repository has no schedule config" do
    close_a_job!

    expect(AgentInsights::Scheduler).not_to have_received(:enqueue_if_idle!)
  end

  it "does not sweep when the schedule config is disabled" do
    AgentInsights::ScheduleConfig.create!(
      repository: repository, enabled: false,
      min_jobs_since_last_run: 1, max_jobs_since_last_run: 2
    )
    Factories.job_record(user: user, repository: repository, state: "closed")
    close_a_job!

    expect(AgentInsights::Scheduler).not_to have_received(:enqueue_if_idle!)
  end

  it "does not sweep while the closed-Job count is below the maximum" do
    enable_insight_config(max: 5)
    3.times { Factories.job_record(user: user, repository: repository, state: "closed") }

    close_a_job! # 4 total closed, max = 5

    expect(AgentInsights::Scheduler).not_to have_received(:enqueue_if_idle!)
  end

  it "sweeps once the closed-Job count reaches the maximum" do
    enable_insight_config(max: 3)
    2.times { Factories.job_record(user: user, repository: repository, state: "closed") }

    close_a_job! # 3 total closed, max = 3

    expect(AgentInsights::Scheduler).to have_received(:enqueue_if_idle!).with(repository)
  end

  it "sweeps when the closed-Job count is already past the maximum" do
    enable_insight_config(max: 3)
    4.times { Factories.job_record(user: user, repository: repository, state: "closed") }

    close_a_job! # 5 total closed, max = 3

    expect(AgentInsights::Scheduler).to have_received(:enqueue_if_idle!).with(repository)
  end

  it "does not chain sweeps off an insight Job's own close" do
    enable_insight_config(max: 2)

    close_a_job!(kind: "agent_insight", issue_number: nil, issue_title: "Insight analysis")

    expect(AgentInsights::Scheduler).not_to have_received(:enqueue_if_idle!)
  end

  it "closes an insight Job outright instead of leaving it implemented" do
    job = Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "agent_insight",
      issue_title: "Insight analysis: #{repository.slug}",
      issue_number: nil,
      state: "running"
    )

    freeze_time do
      expect { job.mark_implemented! }.to change(job, :state).from("running").to("closed")

      expect(job.closure_reason).to eq("agent_insight")
      expect(job.finished_at).to eq(Time.current)
    end
  end
end
