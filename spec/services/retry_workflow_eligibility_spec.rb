require "rails_helper"

RSpec.describe RetryWorkflowEligibility do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def make_job(**overrides)
    Factories.job_record(user: user, repository: repository, state: "failed", **overrides)
  end

  def make_workflow(job, trigger_kind: "initial", state: "failed")
    Workflow.create!(job: job, trigger_kind: trigger_kind).tap do |wf|
      wf.update_columns(state: state, started_at: 10.minutes.ago, finished_at: 1.minute.ago) if state != "queued"
    end
  end

  def make_started_workflow(job)
    wf = make_workflow(job)
    Step.create!(workflow: wf, kind: "implement", position: 0).tap do |step|
      step.runs.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
    end
    wf
  end

  describe "#call" do
    it "is eligible for a failed job with a prior initial workflow run" do
      job = make_job
      make_started_workflow(job)

      result = described_class.call(job: job)

      expect(result).to be_eligible
      expect(result.code).to be_nil
    end

    it "is ineligible when the job is closed" do
      job = Factories.job_record(user: user, repository: repository, state: "closed", closure_reason: "pr_merged")

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("closed")
    end

    it "is ineligible when the job is approved" do
      job = Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 1).tap do |j|
        j.approve!(via: "operator")
        j.save!
      end

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("approved")
    end

    it "is ineligible when the job is in landing state" do
      job = Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 1).tap do |j|
        j.approve!(via: "operator")
        j.save!
        j.update_columns(state: "landing")
      end

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("approved")
    end

    it "is ineligible when the job has a landing failure reason" do
      job = make_job(landing_failure_reason: "merge conflict")

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("landing_failed")
    end

    it "is ineligible when there is another active run on the job" do
      job = make_job
      make_started_workflow(job)
      # Add an extra active run outside of any specific workflow
      job.runs.create!(trigger_kind: "retry", state: "running", started_at: 1.minute.ago)

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("active_run")
    end

    it "is ineligible when another retry workflow is already active" do
      job = make_job
      make_started_workflow(job)
      Workflow.create!(job: job, trigger_kind: "retry", state: "queued")

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("duplicate_retry")
    end

    it "is ineligible when the PR is already current and passing" do
      job = make_job(
        pr_number: 77,
        branch_name: "syrus/direct-ready",
        commits_behind_base: 0,
        pr_checks_state: "passing"
      )
      make_started_workflow(job)

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("pr_ready")
    end

    it "is ineligible when the provided retry workflow has been superseded by a newer success" do
      job = make_job(pr_number: 77, branch_name: "syrus/direct-77")
      make_started_workflow(job)
      older = make_workflow(job, trigger_kind: "retry", state: "running")
      newer = make_workflow(job, trigger_kind: "retry", state: "succeeded")
      newer.update!(artifacts: { "publication_branch" => "syrus/direct-77" })

      result = described_class.call(job: job, workflow: older)

      expect(result).not_to be_eligible
      expect(result.code).to eq("superseded")
    end

    it "is ineligible when the initial workflow has never run" do
      job = make_job
      # Create an initial workflow in queued state with no runs
      Workflow.create!(job: job, trigger_kind: "initial")

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("initial_not_run")
    end

    it "is ineligible when there is no initial workflow at all" do
      job = make_job

      result = described_class.call(job: job)

      expect(result).not_to be_eligible
      expect(result.code).to eq("initial_not_run")
    end

    context "when a workflow is provided" do
      it "does not count the provided workflow's own steps as blocking active runs" do
        job = make_job
        # A non-initial run that ran before
        make_started_workflow(job)
        # The workflow being retried — its active step should NOT block eligibility
        retry_wf = make_workflow(job, trigger_kind: "retry", state: "queued")
        step = Step.create!(workflow: retry_wf, kind: "implement", position: 0)
        step.runs.create!(job: job, trigger_kind: "retry", state: "queued")

        result = described_class.call(job: job, workflow: retry_wf)

        expect(result).to be_eligible
      end
    end
  end
end
