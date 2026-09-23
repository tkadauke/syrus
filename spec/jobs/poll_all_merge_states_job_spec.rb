require "rails_helper"

RSpec.describe PollAllMergeStatesJob do
  it "fans out to PollMergeStateJob for Syrus-authored PRs" do
    syrus_pr = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    no_pr = Factories.job

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMergeStateJob).with(syrus_pr.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(no_pr.id)
  end

  it "fans out to PollMergeStateJob for external PRs (preempted-Job ingest path)" do
    external = Factories.job
    external.update!(state: "closed", closure_reason: "preempted",
                     external_pr_number: 99, finished_at: Time.current)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMergeStateJob).with(external.id)
  end

  it "does not fan out for closed Syrus-authored PRs" do
    closed = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    closed.close!
    closed.save!

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(closed.id)
  end

  it "skips jobs whose repository GitHub App installation is rate-limited" do
    user = Factories.user
    repo = Factories.repository(user: user)
    installation = Factories.installation(
      user: user,
      account_login: repo.owner,
      gh_rate_limit_remaining: 0,
      gh_rate_limit_reset_at: 30.minutes.from_now,
      gh_rate_limit_observed_at: Time.current
    )
    repo.update!(installation: installation)
    job = Factories.job(repository: repo, pr_number: 17, branch_name: "syrus/issue-17")

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(job.id)
  end

  it "skips Jobs whose Repository is archived" do
    archived_repo = Factories.repository
    archived_repo.archive!
    archived_job = Factories.job(repository: archived_repo, pr_number: 11, branch_name: "syrus/x")

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(archived_job.id)
  end

  it "is inert when polling is paused" do
    AppSetting.current.update!(polling_paused: true)
    Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")

    expect { described_class.perform_now }.not_to have_enqueued_job(PollMergeStateJob)
  ensure
    AppSetting.current.update!(polling_paused: false)
  end

  describe "merge-state polling cadence" do
    # Anchored relative to the real `Time.current` captured *before*
    # `travel_to` -- unlike an epoch-zero anchor, this keeps the
    # travelled-to instant close enough to "now" (within a few rotation
    # ticks) that a `2.hours.ago` `updated_at` recorded before travelling
    # still reads as stale once we jump to it.
    def slot_time_for(job, aligned:)
      slots = [ GithubPollingBudget.send(:interval_for, :merge_state).to_i / GithubPollingBudget::BASE_TICK_SECONDS, 1 ].max
      base_tick = Time.current.to_i / GithubPollingBudget::BASE_TICK_SECONDS
      target = job.id % slots
      target = (target + 1) % slots unless aligned
      delta = (target - (base_tick % slots)) % slots
      Time.at((base_tick + delta) * GithubPollingBudget::BASE_TICK_SECONDS)
    end

    it "does not fan out to a stale running Job outside its low-frequency merge-state rotation slot" do
      stale_running = Factories.job(pr_number: 21, branch_name: "syrus/issue-21-1")
      stale_running.update_columns(state: "running", updated_at: 2.hours.ago)
      travel_target = slot_time_for(stale_running, aligned: false)

      travel_to(travel_target) do
        expect {
          described_class.perform_now
        }.not_to have_enqueued_job(PollMergeStateJob).with(stale_running.id)
      end
    end

    it "eventually fans out to a stale running Job once its low-frequency rotation slot comes up" do
      stale_running = Factories.job(pr_number: 23, branch_name: "syrus/issue-23-1")
      stale_running.update_columns(state: "running", updated_at: 2.hours.ago)
      travel_target = slot_time_for(stale_running, aligned: true)

      travel_to(travel_target) do
        expect {
          described_class.perform_now
        }.to have_enqueued_job(PollMergeStateJob).with(stale_running.id)
      end
    end

    it "still fans out to a stale approved Job (landing-relevant) regardless of rotation slot" do
      stale_approved = Factories.job(pr_number: 22, branch_name: "syrus/issue-22-1")
      stale_approved.update_columns(state: "approved", updated_at: 2.hours.ago, approved_at: 2.hours.ago)
      travel_target = slot_time_for(stale_approved, aligned: false)

      travel_to(travel_target) do
        expect {
          described_class.perform_now
        }.to have_enqueued_job(PollMergeStateJob).with(stale_approved.id)
      end
    end

    it "fans out to a recently updated non-landing Job via the change-triggered fast path" do
      recently_failed = Factories.job(pr_number: 24, branch_name: "syrus/issue-24-1")
      recently_failed.update_columns(state: "failed", updated_at: 5.minutes.ago)
      travel_target = slot_time_for(recently_failed, aligned: false)

      travel_to(travel_target) do
        expect {
          described_class.perform_now
        }.to have_enqueued_job(PollMergeStateJob).with(recently_failed.id)
      end
    end
  end
end
