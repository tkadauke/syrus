require "rails_helper"

# workflow-engine-v3 C2. Intake sat off the engine: because classification is
# not a Run, the reconciler could not see a Job stuck waiting for one, so
# ReapClassifierPendingJob reimplemented stale-work reaping the reconciler
# already does properly. Detection belongs here; the private sweep is gone.
RSpec.describe "Stalled intake reconciliation" do
  include ActiveJob::TestHelper

  let(:job) { Factories.job_record }

  def stall!(age: 30.minutes)
    job.update_columns(
      state: "triaging", triaging_reason: "classifier_pending", created_at: age.ago
    )
  end

  def reconcile
    WorkEngine::Reconciler.call(source: "stalled_intake_spec", job_id: job.id)
  end

  def issue(result) = result.issues.find { |candidate| candidate.kind == "stalled_classifier_pending_job" }

  it "detects a Job that has been waiting on classification too long" do
    stall!

    found = issue(reconcile)

    expect(found).to be_present
    expect(found.recommended_repair_action).to eq("reclassify_stalled_intake")
    expect(found.safe_to_auto_repair).to be(true)
    expect(found.affected_ids[:job_ids]).to include(job.id)
  end

  # A classify that is genuinely still in flight is not stalled.
  it "leaves a recently created Job alone" do
    stall!(age: 1.minute)

    expect(issue(reconcile)).to be_nil
  end

  it "leaves a Job that is no longer waiting on classification alone" do
    stall!
    job.update_columns(triaging_reason: "needs_more_detail")

    expect(issue(reconcile)).to be_nil
  end

  # `classifier_uncertain` used to be terminal by omission: nothing re-ran the
  # classifier, nothing reaped it, nothing surfaced it, and polling dedups on
  # the existing Job -- so one transient provider error stranded the Job for
  # good. JOB-3184 sat that way for three weeks.
  describe "a Job the classifier gave up on" do
    def uncertain!(attempts: 1, age: 30.minutes)
      job.update_columns(
        state: "triaging", triaging_reason: "classifier_uncertain",
        classifier_attempts: attempts, created_at: age.ago
      )
    end

    it "is detected so it can be classified once more" do
      uncertain!

      expect(issue(reconcile)&.affected_ids&.dig(:job_ids)).to include(job.id)
    end

    # The cap is what keeps the retry from becoming a loop. Past it, an
    # uncertain Job is a person's call, which the triage decision carries.
    it "is left alone once the retry budget is spent" do
      uncertain!(attempts: Job::MAX_CLASSIFIER_ATTEMPTS)

      expect(issue(reconcile)).to be_nil
    end

    it "is put back in the classifier's queue by the repair" do
      uncertain!
      plan = WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "stalled_classifier_pending_job", action: "reclassify_stalled_intake",
        auto_executable: true, target_type: "job", target_id: job.id,
        affected_ids: { job_ids: [ job.id ] }, execution_steps: [], preconditions: {},
        reason: "test"
      )

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to have_enqueued_job(ClassifyIssueJob).with(job.id)

      # IngestionClassifier and ClassifyIssueJob both refuse any reason but
      # classifier_pending, so the flip has to happen for the retry to run.
      expect(job.reload.triaging_reason).to eq("classifier_pending")
      expect(job.triaging_uncertainty_reason).to be_nil
    end
  end

  describe "the repair" do
    it "re-enqueues classification" do
      stall!
      plan = WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "stalled_classifier_pending_job", action: "reclassify_stalled_intake",
        auto_executable: true, target_type: "job", target_id: job.id,
        affected_ids: { job_ids: [ job.id ] }, execution_steps: [], preconditions: {},
        reason: "test"
      )

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to have_enqueued_job(ClassifyIssueJob).with(job.id)
    end
  end

  it "no longer ships the private sweep it replaced" do
    expect(defined?(ReapClassifierPendingJob)).to be_nil
    expect(Rails.root.join("config/recurring.yml").read).not_to include("ReapClassifierPendingJob")
  end
end
