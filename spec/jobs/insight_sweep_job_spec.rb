require "rails_helper"

RSpec.describe InsightSweepJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def enable_agent_insights!
    feature = Feature.find_or_create_by!(slug: "agent_insights") do |f|
      f.category = "Labs"
      f.name = "Agent Insights"
    end
    feature.update!(enabled: true)
  end

  def enable_config(repo, **attrs)
    InsightScheduleConfig.create!({
      repository: repo,
      enabled: true,
      min_jobs_since_last_run: 3,
      max_jobs_since_last_run: 10
    }.merge(attrs))
  end

  def closed_coding_job(repo)
    Factories.job_record(user: repo.user, repository: repo, state: "closed")
  end

  before do
    allow(InsightScheduler).to receive(:enqueue_if_idle!)
  end

  it "does nothing when the agent_insights feature is off" do
    enable_config(repository)
    3.times { closed_coding_job(repository) }

    described_class.perform_now

    expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
  end

  context "when agent_insights is enabled" do
    before { enable_agent_insights! }

    it "skips repos with count below min" do
      enable_config(repository, min_jobs_since_last_run: 5)
      4.times { closed_coding_job(repository) }

      described_class.perform_now

      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "enqueues for repos with count at min" do
      enable_config(repository, min_jobs_since_last_run: 3)
      3.times { closed_coding_job(repository) }

      described_class.perform_now

      expect(InsightScheduler).to have_received(:enqueue_if_idle!).with(repository)
    end

    it "enqueues for repos with count above min" do
      enable_config(repository, min_jobs_since_last_run: 3)
      5.times { closed_coding_job(repository) }

      described_class.perform_now

      expect(InsightScheduler).to have_received(:enqueue_if_idle!).with(repository)
    end

    it "skips repos whose InsightScheduleConfig is disabled" do
      InsightScheduleConfig.create!(repository: repository, enabled: false, min_jobs_since_last_run: 1, max_jobs_since_last_run: 5)
      3.times { closed_coding_job(repository) }

      described_class.perform_now

      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "skips archived repositories" do
      enable_config(repository, min_jobs_since_last_run: 1)
      closed_coding_job(repository)
      repository.archive!

      described_class.perform_now

      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!)
    end

    it "processes multiple repositories independently" do
      repo2 = Factories.repository(user: user)
      enable_config(repository, min_jobs_since_last_run: 3)
      enable_config(repo2, min_jobs_since_last_run: 3)

      3.times { closed_coding_job(repository) }
      2.times { closed_coding_job(repo2) }  # below min for repo2

      described_class.perform_now

      expect(InsightScheduler).to have_received(:enqueue_if_idle!).with(repository)
      expect(InsightScheduler).not_to have_received(:enqueue_if_idle!).with(repo2)
    end

    it "isolates one repo's failure from the rest" do
      repo2 = Factories.repository(user: user)
      enable_config(repository, min_jobs_since_last_run: 1)
      enable_config(repo2, min_jobs_since_last_run: 1)
      closed_coding_job(repository)
      closed_coding_job(repo2)

      call_count = 0
      allow(InsightScheduler).to receive(:enqueue_if_idle!) do |repo|
        call_count += 1
        raise "boom" if call_count == 1
      end

      expect { described_class.perform_now }.not_to raise_error
      expect(call_count).to eq(2)
    end
  end
end
