require "rails_helper"

RSpec.describe GithubPollingBudget do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # A fixed anchor so slot-alignment math (based on `now.to_i`) stays
  # self-consistent regardless of when the suite actually runs -- both
  # `now` and `updated_at` below are always computed relative to this
  # same reference point rather than the real wall clock.
  REFERENCE_TIME = Time.zone.local(2026, 1, 1, 0, 0, 0)

  def job_in_state(state, updated_at: REFERENCE_TIME - 2.hours)
    job = Factories.job(user: user, repository: repository, pr_number: rand(1_000..999_999), branch_name: "syrus/budget-#{SecureRandom.hex(4)}")
    job.update_columns(state: state, updated_at: updated_at)
    job
  end

  # Finds a `now` near REFERENCE_TIME whose rotation slot does (or does
  # not) match the Job's `id % slots` bucket -- see
  # `GithubPollingBudget#poll_job_now?`'s low-frequency rotation.
  def slot_time_for(job, kind:, aligned:)
    slots = [ described_class.send(:interval_for, kind).to_i / described_class::BASE_TICK_SECONDS, 1 ].max
    base_tick = REFERENCE_TIME.to_i / described_class::BASE_TICK_SECONDS
    target = job.id % slots
    target = (target + 1) % slots unless aligned
    delta = (target - (base_tick % slots)) % slots
    Time.at((base_tick + delta) * described_class::BASE_TICK_SECONDS)
  end

  describe ".poll_job_now?" do
    %w[ landing approved ].each do |state|
      it "always polls #{state} Jobs for merge_state, regardless of rotation slot" do
        job = job_in_state(state)
        now = slot_time_for(job, kind: :merge_state, aligned: false)

        expect(described_class.poll_job_now?(job, kind: :merge_state, now: now)).to be true
      end
    end

    %w[ running failed blocked_by_epic implemented ].each do |state|
      it "does not treat a stale #{state} Job as urgent for merge_state" do
        job = job_in_state(state)
        now = slot_time_for(job, kind: :merge_state, aligned: false)

        expect(described_class.poll_job_now?(job, kind: :merge_state, now: now)).to be false
      end
    end

    it "still treats running Jobs as urgent for pr_feedback (comment/close discovery)" do
      job = job_in_state("running")
      now = slot_time_for(job, kind: :pr_feedback, aligned: false)

      expect(described_class.poll_job_now?(job, kind: :pr_feedback, now: now)).to be true
    end

    it "still treats running Jobs as urgent for external_pr" do
      job = job_in_state("running")
      now = slot_time_for(job, kind: :external_pr, aligned: false)

      expect(described_class.poll_job_now?(job, kind: :external_pr, now: now)).to be true
    end

    it "polls a recently updated non-urgent Job regardless of state (change-triggered fast path)" do
      job = job_in_state("failed", updated_at: REFERENCE_TIME - 5.minutes)
      now = slot_time_for(job, kind: :merge_state, aligned: false)

      expect(described_class.poll_job_now?(job, kind: :merge_state, now: now)).to be true
    end

    it "still polls a stale non-urgent Job once its low-frequency rotation slot comes up" do
      job = job_in_state("failed")
      now = slot_time_for(job, kind: :merge_state, aligned: true)

      expect(described_class.poll_job_now?(job, kind: :merge_state, now: now)).to be true
    end
  end

  describe ".take_pollable_jobs" do
    it "prioritizes landing-relevant states first and respects the limit" do
      landing = job_in_state("landing")
      approved = job_in_state("approved")
      stale_running = job_in_state("running")
      now = slot_time_for(stale_running, kind: :merge_state, aligned: false)

      selected = described_class.take_pollable_jobs(
        Job.where(id: [ landing.id, approved.id, stale_running.id ]),
        kind: :merge_state,
        limit: 2,
        now: now
      )

      expect(selected).to contain_exactly(landing, approved)
    end

    it "excludes a stale, out-of-slot running Job from merge_state polling even with budget to spare" do
      landing = job_in_state("landing")
      stale_running = job_in_state("running")
      now = slot_time_for(stale_running, kind: :merge_state, aligned: false)

      selected = described_class.take_pollable_jobs(
        Job.where(id: [ landing.id, stale_running.id ]),
        kind: :merge_state,
        limit: 10,
        now: now
      )

      expect(selected).to contain_exactly(landing)
    end
  end
end
