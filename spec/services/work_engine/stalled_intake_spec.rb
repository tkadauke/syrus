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

  def with_solid_queue_adapter
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  def failed_solid_queue_classify(stalled_job)
    active_job = ClassifyIssueJob.new(stalled_job.id)
    solid_queue_job = SolidQueue::Job.enqueue(active_job)
    SolidQueue::ReadyExecution.where(job_id: solid_queue_job.id).delete_all
    SolidQueue::FailedExecution.create!(
      job_id: solid_queue_job.id,
      error: {
        "exception_class" => "SolidQueue::Processes::ProcessPrunedError",
        "message" => "Process was found dead and pruned"
      }
    )
    solid_queue_job
  end

  def repair_plan_for(*jobs)
    WorkEngine::RepairPlanner::Plan.new(
      issue_kind: "stalled_classifier_pending_job", action: "reclassify_stalled_intake",
      auto_executable: true, target_type: "job", target_id: jobs.first.id,
      affected_ids: { job_ids: jobs.map(&:id) }, execution_steps: [], preconditions: {},
      reason: "test"
    )
  end

  it "detects a Job that has been waiting on classification too long" do
    stall!

    found = issue(reconcile)

    expect(found).to be_present
    expect(found.recommended_repair_action).to eq("reclassify_stalled_intake")
    expect(found.safe_to_auto_repair).to be(true)
    expect(found.affected_ids[:job_ids]).to include(job.id)
  end

  it "plans the automatic reclassification repair" do
    stall!

    plan = reconcile.repair_plans.find { |candidate| candidate.issue_kind == "stalled_classifier_pending_job" }

    expect(plan.action).to eq("reclassify_stalled_intake")
    expect(plan.auto_executable).to be(true)
    expect(plan.target_type).to eq("Job")
    expect(plan.target_id).to eq(job.id)
    expect(plan.execution_steps).to eq([ "ClassifyIssueJob.enqueue_for_job!" ])
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

  it "leaves a pending Job alone once re-enqueue retries are spent" do
    stall!
    job.update_columns(classifier_attempts: Job::MAX_CLASSIFIER_ATTEMPTS)

    expect(issue(reconcile)).to be_nil
  end

  # `classifier_uncertain` used to be terminal by omission: nothing re-ran the
  # classifier, nothing reaped it, nothing surfaced it, and polling dedups on
  # the existing Job -- so one transient provider error stranded the Job for
  # good. A production Job sat that way for three weeks.
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
      plan = repair_plan_for(job)

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to have_enqueued_job(ClassifyIssueJob).with(job.id)

      # IngestionClassifier and ClassifyIssueJob both refuse any reason but
      # classifier_pending, so the flip has to happen for the retry to run.
      expect(job.reload.triaging_reason).to eq("classifier_pending")
      expect(job.triaging_uncertainty_reason).to be_nil
    end

    it "audits the reconciler-owned retry mutation" do
      uncertain!
      plan = WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "stalled_classifier_pending_job", action: "reclassify_stalled_intake",
        auto_executable: true, target_type: "job", target_id: job.id,
        affected_ids: { job_ids: [ job.id ] }, execution_steps: [], preconditions: {},
        reason: "test"
      )

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to change { StateTransition.where(subject: job, event_name: "reclassify_stalled_intake", source: "reconciler").count }.from(0).to(1)

      transition = StateTransition.where(subject: job, event_name: "reclassify_stalled_intake").last
      expect(transition.metadata).to include(
        "repair_action" => "reclassify_stalled_intake",
        "issue_kind" => "stalled_classifier_pending_job",
        "from_triaging_reason" => "classifier_uncertain",
        "triaging_reason" => "classifier_pending"
      )
    end
  end

  describe "the repair" do
    it "re-enqueues classification" do
      stall!
      plan = repair_plan_for(job)

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to have_enqueued_job(ClassifyIssueJob).with(job.id)
    end

    it "spends retry budget for a pending Job so repeated lost queue jobs stop looping" do
      stall!
      plan = repair_plan_for(job)

      expect {
        WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute
      }.to change { job.reload.classifier_attempts }.by(1)
    end

    it "clears a pruned failed classifier execution so the repair creates a runnable attempt" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      stall!

      with_solid_queue_adapter do
        failed_queue_job = failed_solid_queue_classify(job)
        plan = repair_plan_for(job)

        result = WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute

        expect(result.status).to eq("applied")
        expect(SolidQueue::Job.where(id: failed_queue_job.id)).to be_empty
        expect(SolidQueue::ReadyExecution.joins(:job).where(solid_queue_jobs: {
          class_name: "ClassifyIssueJob",
          concurrency_key: ClassifyIssueJob.solid_queue_concurrency_key_for(job.id)
        })).to exist
      end
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end

    it "recovers multiple pruned classifier executions without operator action" do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
      stalled_jobs = [ job, Factories.job_record, Factories.job_record ]
      stalled_jobs.each do |stalled_job|
        stalled_job.update_columns(
          state: "triaging", triaging_reason: "classifier_pending", created_at: 30.minutes.ago
        )
      end

      with_solid_queue_adapter do
        failed_queue_jobs = stalled_jobs.map { |stalled_job| failed_solid_queue_classify(stalled_job) }
        plan = repair_plan_for(*stalled_jobs)

        result = WorkEngine::RepairExecutor::Policies::Base.for(plan.action).new(plan: plan, now: Time.current).execute

        expect(result.status).to eq("applied")
        expect(SolidQueue::Job.where(id: failed_queue_jobs.map(&:id))).to be_empty
        stalled_jobs.each do |stalled_job|
          expect(SolidQueue::ReadyExecution.joins(:job).where(solid_queue_jobs: {
            class_name: "ClassifyIssueJob",
            concurrency_key: ClassifyIssueJob.solid_queue_concurrency_key_for(stalled_job.id)
          })).to exist
        end
      end
    ensure
      clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    end
  end

  it "no longer ships the private sweep it replaced" do
    expect(defined?(ReapClassifierPendingJob)).to be_nil
    expect(Rails.root.join("config/recurring.yml").read).not_to include("ReapClassifierPendingJob")
  end
end
