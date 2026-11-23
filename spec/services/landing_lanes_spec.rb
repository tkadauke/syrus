require "rails_helper"

RSpec.describe "Parallel landing lanes", :ci_only do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def queue_job(issue_number, repo: repository)
    Factories.job_record(user: user, repository: repo, issue_number: issue_number, pr_number: issue_number, state: "implemented").tap do |job|
      job.approve!(via: "github_review")
      job.update!(approved_at: (30 - issue_number).minutes.ago, github_mergeable_state: "clean", mergeability_checked_at: Time.current)
    end
  end

  def landing_lock_keys
    WorkUnitLock.active.where("lock_key LIKE ?", "landing:repository:%").pluck(:lock_key).sort
  end

  describe WorkDefinitions do
    let(:job) { queue_job(1) }

    it "keeps the lane-1 key byte for byte and adds a lane suffix for further lanes" do
      expect(described_class.landing_lock_key_for(job)).to eq("landing:repository:#{repository.id}")
      expect(described_class.landing_lock_key_for(job, lane: 1)).to eq("landing:repository:#{repository.id}")
      expect(described_class.landing_lock_key_for(job, lane: 3)).to eq("landing:repository:#{repository.id}:lane:3")
    end

    it "derives the merge lock key from the lane-less landing key" do
      expect(described_class.merge_lock_key_for(job)).to eq("merge:repository:#{repository.id}")
    end

    it "lists one key per configured lane" do
      expect(described_class.landing_lane_keys_for(job)).to eq([ "landing:repository:#{repository.id}" ])
      repository.update!(landing_concurrency: 3)
      expect(described_class.landing_lane_keys_for(job.reload)).to eq(
        [ "landing:repository:#{repository.id}", "landing:repository:#{repository.id}:lane:2", "landing:repository:#{repository.id}:lane:3" ]
      )
    end

    it "maps a key back to its lane" do
      expect(described_class.landing_lane_for_key("landing:repository:4")).to eq(1)
      expect(described_class.landing_lane_for_key("landing:repository:4:lane:2:branch:hotfix")).to eq(2)
    end
  end

  describe Repository do
    it "defaults to one lane and accepts 1 to 5" do
      expect(repository.landing_concurrency).to eq(1)
      expect(repository).to be_valid
      repository.landing_concurrency = 5
      expect(repository).to be_valid
      [ 0, 6 ].each do |bad|
        repository.landing_concurrency = bad
        expect(repository).not_to be_valid
      end
    end
  end

  describe LandingQueueProcessor do
    it "lands one unit at a time with the default of one lane" do
      jobs = (1..2).map { |n| queue_job(n) }

      described_class.call

      expect(jobs.map { |job| job.reload.state }).to eq(%w[landing approved])
      expect(landing_lock_keys).to eq([ "landing:repository:#{repository.id}" ])
    end

    it "dispatches three units concurrently with three lanes and holds a fourth until a lane frees" do
      repository.update!(landing_concurrency: 3)
      jobs = (1..4).map { |n| queue_job(n) }

      described_class.call

      expect(jobs.map { |job| job.reload.state }).to eq(%w[landing landing landing approved])
      base = "landing:repository:#{repository.id}"
      expect(landing_lock_keys).to eq([ base, "#{base}:lane:2", "#{base}:lane:3" ].sort)

      # A fresh pass with every lane occupied dispatches nothing.
      expect(described_class.call).to be_nil
      expect(jobs.last.reload).to be_approved

      jobs.first.workflows.last.work_unit.release_landing_locks!
      jobs.first.workflows.last.work_unit.update!(state: "succeeded")
      jobs.first.update!(state: "closed")

      described_class.call

      expect(jobs.last.reload).to be_landing
      expect(landing_lock_keys).to include(base)
    end

    it "keeps a failed unit's lane held without blocking the other lanes" do
      repository.update!(landing_concurrency: 2)
      first, second, third = (1..3).map { |n| queue_job(n) }

      described_class.call
      expect([ first, second ].map { |job| job.reload.state }).to eq(%w[landing landing])

      # The second unit finishes; only its own lane frees, the first keeps its.
      unit = second.workflows.last.work_unit
      unit.release_landing_locks!
      unit.update!(state: "succeeded")
      second.update!(state: "closed")

      described_class.call

      expect(third.reload).to be_landing
      expect(first.reload).to be_landing
      expect(landing_lock_keys.size).to eq(2)
    end

    it "keeps a Job out of two landing units" do
      repository.update!(landing_concurrency: 2)
      job = queue_job(1)

      described_class.call
      described_class.call

      expect(job.workflows.where(trigger_kind: "auto_merge").count).to eq(1)
      expect(landing_lock_keys).to eq([ "landing:repository:#{repository.id}" ])
    end
  end
end
