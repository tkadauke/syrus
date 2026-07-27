require "rails_helper"

RSpec.describe JobWorkflowAccessors do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # A freshly-created job already has one initial Workflow; strip it so each
  # example controls the workflow set explicitly.
  let(:job) do
    j = Factories.job(user: user, repository: repository)
    j.workflows.destroy_all
    j.reload
  end

  def create_workflow(**attrs)
    Workflow.create!({ job: job, user: job.user, trigger_kind: "initial" }.merge(attrs))
  end

  # --- latest_workflow -------------------------------------------------------

  describe "#latest_workflow" do
    it "returns nil when the job has no workflows" do
      expect(job.latest_workflow).to be_nil
    end

    it "returns the sole workflow" do
      wf = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      expect(job.latest_workflow).to eq(wf)
    end

    it "prefers a running workflow over a finished one" do
      _finished = create_workflow(state: "succeeded", finished_at: 2.hours.ago)
      running   = create_workflow(state: "running",   finished_at: nil)
      expect(job.latest_workflow).to eq(running)
    end

    it "prefers a queued workflow over a finished one" do
      _finished = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      queued    = create_workflow(state: "queued",    finished_at: nil)
      expect(job.latest_workflow).to eq(queued)
    end

    it "among finished workflows returns the most recently-finished one" do
      older  = create_workflow(state: "succeeded", finished_at: 2.hours.ago)
      newer  = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      expect(job.latest_workflow).to eq(newer)
      expect(job.latest_workflow).not_to eq(older)
    end

    it "breaks a finished_at tie by returning the highest ID" do
      ts      = 30.minutes.ago
      lower_id = create_workflow(state: "failed",    finished_at: ts)
      higher_id = create_workflow(state: "succeeded", finished_at: ts)
      # Ensure higher_id really is higher
      expect(higher_id.id).to be > lower_id.id
      expect(job.latest_workflow).to eq(higher_id)
    end

    context "when workflows are already loaded (in-memory path)" do
      it "returns the same result as the SQL path" do
        _finished = create_workflow(state: "succeeded", finished_at: 2.hours.ago)
        active    = create_workflow(state: "running",   finished_at: nil)

        job.workflows.load  # force loaded?
        expect(job.workflows).to be_loaded

        expect(job.latest_workflow).to eq(active)
      end

      it "among finished workflows in memory picks the most recently-finished" do
        older = create_workflow(state: "succeeded", finished_at: 3.hours.ago)
        newer = create_workflow(state: "succeeded", finished_at: 1.hour.ago)

        job.workflows.load
        result = job.latest_workflow
        expect(result).to eq(newer)
        expect(result).not_to eq(older)
      end
    end
  end

  # --- latest_workflow_id ----------------------------------------------------

  describe "#latest_workflow_id" do
    it "delegates to latest_workflow when the virtual attribute is absent" do
      wf = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      expect(job.latest_workflow_id).to eq(wf.id)
    end

    it "reads the virtual attribute column when present (avoids extra query)" do
      wf = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      # Simulate a raw SQL select that injects latest_workflow_id as an attribute.
      result = Job.where(id: job.id)
                  .select("jobs.*, #{wf.id} AS latest_workflow_id")
                  .first

      expect(result).to have_attribute(:latest_workflow_id)
      expect(result.latest_workflow_id).to eq(wf.id)
    end
  end

  # --- latest_workflow_state -------------------------------------------------

  describe "#latest_workflow_state" do
    it "returns 'queued' when there are no workflows" do
      expect(job.latest_workflow_state).to eq("queued")
    end

    it "returns the actual state of the latest workflow" do
      create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      expect(job.reload.latest_workflow_state).to eq("succeeded")
    end
  end

  # --- latest_workflow_trigger_kind ------------------------------------------

  describe "#latest_workflow_trigger_kind" do
    it "returns nil when there are no workflows" do
      expect(job.latest_workflow_trigger_kind).to be_nil
    end

    it "returns the trigger_kind of the latest workflow" do
      create_workflow(state: "running", trigger_kind: "pr_comment", finished_at: nil)
      expect(job.reload.latest_workflow_trigger_kind).to eq("pr_comment")
    end
  end

  # --- latest_workflow_created_at --------------------------------------------

  describe "#latest_workflow_created_at" do
    it "returns nil when there is no latest workflow" do
      expect(job.latest_workflow_created_at).to be_nil
    end

    it "returns the created_at of the latest workflow as a Time" do
      wf = create_workflow(state: "running", finished_at: nil)
      expect(job.reload.latest_workflow_created_at).to be_within(1.second).of(wf.created_at)
    end

    it "parses a String value from a raw SQL virtual attribute into a Time" do
      wf = create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      ts_string = wf.created_at.utc.iso8601

      result = Job.where(id: job.id)
                  .select("jobs.*, '#{ts_string}' AS latest_workflow_created_at")
                  .first

      expect(result).to have_attribute(:latest_workflow_created_at)
      value = result.latest_workflow_created_at
      expect(value).to be_a(Time)
      expect(value).to be_within(1.second).of(wf.created_at)
    end
  end

  # --- active_workflow_trigger_kind ------------------------------------------

  describe "#active_workflow_trigger_kind" do
    it "returns nil when there are no active workflows" do
      create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      expect(job.reload.active_workflow_trigger_kind).to be_nil
    end

    it "returns the trigger_kind of the active workflow" do
      create_workflow(state: "succeeded", finished_at: 1.hour.ago)
      create_workflow(state: "running", trigger_kind: "auto_merge", finished_at: nil)
      expect(job.reload.active_workflow_trigger_kind).to eq("auto_merge")
    end

    it "returns the latest active workflow's trigger_kind when multiple are active" do
      earlier = create_workflow(state: "queued",   trigger_kind: "initial",    finished_at: nil)
      later   = create_workflow(state: "running",  trigger_kind: "pr_comment", finished_at: nil)
      expect(later.id).to be > earlier.id

      result = job.reload.active_workflow_trigger_kind
      expect(result).to eq("pr_comment")
    end

    context "when workflows association is loaded in memory" do
      it "returns the same result as the SQL path" do
        create_workflow(state: "succeeded", finished_at: 1.hour.ago)
        active = create_workflow(state: "running", trigger_kind: "retry", finished_at: nil)

        job.workflows.load
        expect(job.active_workflow_trigger_kind).to eq("retry")
        _ = active  # suppress unused warning
      end
    end
  end
end
