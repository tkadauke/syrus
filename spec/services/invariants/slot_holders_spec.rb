require "rails_helper"

RSpec.describe Invariants::SlotHolders do
  let(:later) { Time.current + 1.hour }
  let(:job) { Factories.job_record(state: "approved") }

  def rebase_unit(workflow_state:, unit_state: "running", **unit_attrs)
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "rebase", state: workflow_state,
                                finished_at: workflow_state.in?(%w[queued running]) ? nil : Time.current)
    attach_work_unit(workflow, kind: "rebase", state: unit_state, **unit_attrs)
  end

  describe "rebase slots" do
    it "reports a counted rebase unit whose workflow is no longer runnable" do
      unit = rebase_unit(workflow_state: "blocked")

      violations = described_class.call(now: later)

      rebase = violations.find { |violation| violation.discriminator == "rebase_slot" }
      expect(rebase).to be_present
      expect(rebase.subject_id).to eq(unit.id)
      expect(rebase.details).to include("slot" => "rebase", "reason" => "workflow_blocked", "slots_held" => 1,
                                        "slots_cap" => PollRebaseJob::CONCURRENT_REBASES_PER_REPO)
      expect(rebase.severity).to eq("warning")
    end

    it "reports a counted rebase unit whose Job is manually paused" do
      rebase_unit(workflow_state: "running")
      job.update_columns(manual_paused: true, manual_paused_at: Time.current)

      reasons = described_class.call(now: later).map { |violation| violation.details["reason"] }

      expect(reasons).to include("job_manually_paused")
    end

    it "is critical when the stale holders fill the repository's rebase cap" do
      PollRebaseJob::CONCURRENT_REBASES_PER_REPO.times do
        other = Factories.job_record(state: "approved", repository: job.repository)
        workflow = Workflow.create!(job: other, user: other.user, trigger_kind: "rebase", state: "cancelled", finished_at: Time.current)
        attach_work_unit(workflow, kind: "rebase", state: "running")
      end

      rebase = described_class.call(now: later).select { |violation| violation.discriminator == "rebase_slot" }

      expect(rebase.size).to eq(PollRebaseJob::CONCURRENT_REBASES_PER_REPO)
      expect(rebase.map(&:severity).uniq).to eq([ "critical" ])
    end

    it "does not report a running rebase, or a paused one that gave its slot up" do
      rebase_unit(workflow_state: "running")
      paused_job = Factories.job_record(state: "approved", repository: job.repository)
      paused = Workflow.create!(job: paused_job, user: paused_job.user, trigger_kind: "rebase", state: "queued")
      attach_work_unit(paused, kind: "rebase", state: "blocked", blocked_reason: "manual_pause")

      expect(described_class.call(now: later)).to be_empty
    end

    it "waits out the grace period" do
      rebase_unit(workflow_state: "cancelled")

      expect(described_class.call(now: Time.current + 5.minutes)).to be_empty
    end
  end

  describe "leaked locks" do
    it "reports an active lock held by a terminal unit" do
      unit = rebase_unit(workflow_state: "succeeded", unit_state: "succeeded")
      unit.update_columns(finished_at: Time.current)
      unit.work_unit_locks.create!(lock_key: "job:#{job.id}") if unit.work_unit_locks.active.none?

      leaked = described_class.call(now: later).select { |violation| violation.details["slot"] == "lock" }

      expect(leaked).not_to be_empty
      expect(leaked.first.details).to include("reason" => "work_unit_succeeded")
    end

    it "does not report released locks of a terminal unit" do
      unit = rebase_unit(workflow_state: "succeeded", unit_state: "succeeded")
      unit.work_unit_locks.active.find_each(&:release!)

      expect(described_class.call(now: later)).to be_empty
    end
  end

  describe "landing lanes" do
    def landing_unit(workflow_state:, unit_state:, **unit_attrs)
      workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "auto_merge", state: workflow_state,
                                  finished_at: workflow_state.in?(%w[queued running]) ? nil : Time.current)
      unit = attach_work_unit(workflow, state: unit_state, **unit_attrs)
      key = WorkDefinitions.landing_lock_key_for(job)
      unit.work_unit_locks.find_or_create_by!(lock_key: key)
      unit.update_columns(blocked_at: Time.current) if unit_state == "blocked"
      unit
    end

    it "reports a landing lane held by a unit blocked on a reason only an operator clears" do
      unit = landing_unit(workflow_state: "queued", unit_state: "blocked", blocked_reason: "no_capable_worker")

      lane = described_class.call(now: later).find { |violation| violation.details["slot"] == "landing_lane" }

      expect(lane).to be_present
      expect(lane.subject_id).to eq(unit.id)
      expect(lane.details).to include("reason" => "blocked_no_capable_worker", "lane" => 1)
    end

    it "reports a landing lane held by a runnable unit whose workflow ended" do
      landing_unit(workflow_state: "failed", unit_state: "running")

      lane = described_class.call(now: later).find { |violation| violation.details["slot"] == "landing_lane" }

      expect(lane.details["reason"]).to eq("workflow_failed")
    end

    it "does not report a landing lane held by a unit waiting on a self-clearing reason" do
      landing_unit(workflow_state: "queued", unit_state: "blocked", blocked_reason: "auto_retry_backoff")

      expect(described_class.call(now: later)).to be_empty
    end
  end
end
