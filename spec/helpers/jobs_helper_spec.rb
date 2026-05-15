require "rails_helper"

RSpec.describe JobsHelper, type: :helper do
  describe "kind labels and pills" do
    it "uses step metadata labels, including newer step kinds" do
      expect(helper.step_kind_label("apply_suggestions")).to eq("Apply suggestions")
      expect(helper.step_kind_label("auto_merge")).to eq("Auto-merge")
    end

    it "uses workflow metadata labels, including newer trigger kinds" do
      expect(helper.workflow_label("auto_merge")).to eq("Auto-merge")
      expect(helper.workflow_label("local_dev")).to eq("Local dev")
    end

    it "renders trigger pills with metadata labels and styles" do
      html = helper.trigger_pill("local_dev")

      expect(html).to include("Local dev")
      expect(html).to include("bg-blue-100 text-blue-700")
    end
  end

  describe "#workflow_label" do
    it "labels retry workflows as Retry" do
      expect(helper.workflow_label("retry")).to eq("Retry")
    end

    it "labels legacy replay trigger values as Retry" do
      expect(helper.workflow_label("replay")).to eq("Retry")
    end
  end

  describe "#job_attention_status" do
    it "has a style for queued attention status" do
      expect(described_class::ATTENTION_STATUS_STYLES["queued"]).to eq("bg-gray-100 text-gray-700")
    end

    it "returns queued when the only run is queued" do
      job = Factories.job

      expect(helper.job_attention_status(job)).to eq("queued")
    end

    it "returns running when a run is running" do
      job = Factories.job
      job.initial_run.update!(state: "running")

      expect(helper.job_attention_status(job)).to eq("running")
    end

    it "prioritizes running when queued and running runs are both present" do
      job = Factories.job
      step = job.initial_run.step
      job.initial_run.update!(state: "running")
      step.runs.create!(
        job: job,
        trigger_kind: "manual",
        agent_provider: job.agent_provider
      )

      expect(helper.job_attention_status(job)).to eq("running")
    end

    it "falls back to awaiting feedback when there are no workflows or runs" do
      job = Factories.job_record(state: "queued")

      expect(helper.job_attention_status(job)).to eq("awaiting feedback")
    end

  end

  describe "#job_summary_state" do
    it "returns 'closed' for a closed Job regardless of latest workflow state" do
      job = Factories.job
      job.update!(state: "closed", closure_reason: "cancelled", finished_at: Time.current)

      expect(helper.job_summary_state(job)).to eq("closed")
    end

    it "returns the Job state directly for every non-closed lifecycle state" do
      %w[triaging blocked_by_epic queued running implemented failed approved landing].each do |state|
        job = Factories.job_record(state: state)

        expect(helper.job_summary_state(job)).to eq(state)
      end
    end

    it "returns 'preempted' instead of 'closed' when an external PR ended the thread" do
      job = Factories.job
      job.update!(state: "closed", closure_reason: "external_pr_merged", finished_at: Time.current)

      expect(helper.job_summary_state(job)).to eq("preempted")
    end

    it "returns 'preempted' when the operator marked the Job preempted" do
      job = Factories.job
      job.update!(state: "closed", closure_reason: "preempted", finished_at: Time.current)

      expect(helper.job_summary_state(job)).to eq("preempted")
    end
  end

  describe "#approval_caption" do
    let(:job) do
      j = Factories.job
      j.update_columns(
        approved_at: Time.zone.parse("2026-05-17T01:13:09Z"),
        approved_via: "github_review",
        approval_evidence: {}
      )
      j
    end

    it "preserves the <time> tag from relative_timestamp as raw HTML" do
      caption = helper.approval_caption(job)

      expect(caption).to be_html_safe
      expect(caption).to include("<time")
      expect(caption).to include('datetime="2026-05-17T01:13:09Z"')
      # Regression: before the safe_join fix, ERB escaped the
      # entire interpolated string and the operator saw
      # `<time datetime=...>` rendered as visible text.
      expect(caption).not_to include("&lt;time")
    end

    it "escapes operator-controllable evidence in the actor name" do
      job.update_column(:approved_via, "auto_rule")
      job.update_column(:approval_evidence, { "rule" => "<script>alert(1)</script>" })

      caption = helper.approval_caption(job)

      expect(caption).to be_html_safe
      expect(caption).not_to include("<script>")
      expect(caption).to include("&lt;script&gt;")
    end

    it "returns a plain string when the job isn't approved" do
      job.update_columns(approved_at: nil, approved_via: nil)
      expect(helper.approval_caption(job)).to eq("Not approved")
    end
  end

  describe "#current_step_caption" do
    let(:job) { job_with_workflow }

    def job_with_workflow
      j = Factories.job
      j
    end

    def add_workflow(job, state:, trigger_kind: "initial")
      wf = Workflow.create!(job: job, trigger_kind: trigger_kind, state: state)
      Step.create!(workflow: wf, kind: "implement", position: 0)
      wf
    end

    it "returns nil when the job has no workflows" do
      j = Factories.job
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is queued" do
      j = Factories.job
      add_workflow(j, state: "queued")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is terminal (succeeded)" do
      j = Factories.job
      add_workflow(j, state: "succeeded")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns nil when the only workflow is terminal (failed)" do
      j = Factories.job
      add_workflow(j, state: "failed")
      expect(helper.current_step_caption(j)).to be_nil
    end

    it "returns a caption when the workflow is running" do
      j = Factories.job
      add_workflow(j, state: "running", trigger_kind: "initial")
      caption = helper.current_step_caption(j)
      expect(caption).to be_present
      expect(caption).to include("currently:")
    end

    it "includes the step kind label for a running workflow" do
      j = Factories.job
      wf = Workflow.create!(job: j, trigger_kind: "initial", state: "running")
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "running")
      caption = helper.current_step_caption(j)
      expect(caption).to include("Implement")
    end
  end
end
