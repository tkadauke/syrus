require "rails_helper"

RSpec.describe ClassifyIssueJob do
  let(:repo) { Factories.repository }
  let(:user) { repo.user }

  # Build a Job that's still in classifier_pending — we can't use
  # Factories.job because that auto-advances past triaging. Drop down
  # to AR directly and let the model's before_validation seed
  # triaging_reason="classifier_pending".
  def pending_job(**attrs)
    Job.create!({
      user: user,
      repository: repo,
      issue_number: 42,
      agent_provider: "claude"
    }.merge(attrs))
  end

  def with_solid_queue_adapter
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter
  end

  def failed_solid_queue_classify(job, exception_class:)
    active_job = described_class.new(job.id)
    solid_queue_job = SolidQueue::Job.enqueue(active_job)
    SolidQueue::ReadyExecution.where(job_id: solid_queue_job.id).delete_all
    SolidQueue::FailedExecution.create!(
      job_id: solid_queue_job.id,
      error: { "exception_class" => exception_class, "message" => "worker vanished" }
    )
    solid_queue_job
  end

  describe "#perform" do
    it "calls IngestionClassifier for an eligible Job" do
      allow(user).to receive(:agent_provider_configured?).with("claude").and_return(true)
      job = pending_job
      allow(Job).to receive(:find).with(job.id).and_return(job)
      allow(job).to receive(:user).and_return(user)

      expect(IngestionClassifier).to receive(:call).with(job: job)

      described_class.perform_now(job.id)
    end

    it "no-ops if the Job has already advanced past classifier_pending" do
      job = pending_job
      job.update_columns(state: "queued", triaging_reason: "classifier_pending")

      expect(IngestionClassifier).not_to receive(:call)

      described_class.perform_now(job.id)
    end

    it "no-ops if the Job's triaging_reason is no longer classifier_pending" do
      job = pending_job
      job.update_columns(triaging_reason: "classifier_uncertain")

      expect(IngestionClassifier).not_to receive(:call)

      described_class.perform_now(job.id)
    end

    it "no-ops if the user's agent provider isn't configured" do
      job = pending_job
      allow(Job).to receive(:find).with(job.id).and_return(job)
      allow(job).to receive(:user).and_return(user)
      allow(user).to receive(:agent_provider_configured?).with("claude").and_return(false)

      expect(IngestionClassifier).not_to receive(:call)

      described_class.perform_now(job.id)
    end

    it "re-enqueues a bounded retry when an infrastructure failure leaves the Job pending" do
      job = pending_job
      allow(Job).to receive(:find).with(job.id).and_return(job)
      allow(job).to receive(:user).and_return(user)
      allow(user).to receive(:agent_provider_configured?).with("claude").and_return(true)
      allow(IngestionClassifier).to receive(:call) do
        job.increment!(:classifier_attempts)
        IngestionClassifier::Result.new(
          epic_id: nil,
          invalid_kind: nil,
          reason: nil,
          evidence_urls: [],
          planned_execution: nil,
          raw_output: nil,
          spawned_process_id: nil,
          error: "ActiveModel::MissingAttributeError: can't write unknown attribute `job_id`"
        )
      end

      expect(described_class).to receive(:enqueue_for_job!).with(job)

      described_class.perform_now(job.id)
    end

    it "does not re-enqueue when a genuine uncertain result parks the Job for triage" do
      job = pending_job
      allow(Job).to receive(:find).with(job.id).and_return(job)
      allow(job).to receive(:user).and_return(user)
      allow(user).to receive(:agent_provider_configured?).with("claude").and_return(true)
      allow(IngestionClassifier).to receive(:call) do
        job.increment!(:classifier_attempts)
        job.mark_classifier_uncertain!
        IngestionClassifier::Result.new(
          epic_id: nil,
          invalid_kind: nil,
          reason: nil,
          evidence_urls: [],
          planned_execution: nil,
          raw_output: "not json",
          spawned_process_id: nil,
          error: "invalid JSON: expected an object"
        )
      end

      expect(described_class).not_to receive(:enqueue_for_job!)

      described_class.perform_now(job.id)
    end

    it "does not re-enqueue infrastructure failures once the classifier attempt cap is spent" do
      job = pending_job(classifier_attempts: Job::MAX_CLASSIFIER_ATTEMPTS - 1)
      allow(Job).to receive(:find).with(job.id).and_return(job)
      allow(job).to receive(:user).and_return(user)
      allow(user).to receive(:agent_provider_configured?).with("claude").and_return(true)
      allow(IngestionClassifier).to receive(:call) do
        job.increment!(:classifier_attempts)
        IngestionClassifier::Result.new(
          epic_id: nil,
          invalid_kind: nil,
          reason: nil,
          evidence_urls: [],
          planned_execution: nil,
          raw_output: nil,
          spawned_process_id: nil,
          error: "ActiveModel::MissingAttributeError: can't write unknown attribute `job_id`"
        )
      end

      expect(described_class).not_to receive(:enqueue_for_job!)

      described_class.perform_now(job.id)
    end

    it "discards (does not raise) if the Job has been deleted" do
      missing_id = 999_999
      expect { described_class.perform_now(missing_id) }.not_to raise_error
    end
  end

  describe ".enqueue_for_job!" do
    before do
      ensure_solid_queue_test_tables!
      clear_solid_queue_test_tables!
    end

    after do
      clear_solid_queue_test_tables!
    end

    it "recovers a pruned failed SolidQueue execution before enqueueing a fresh classifier attempt" do
      job = pending_job
      failed_job = nil

      with_solid_queue_adapter do
        failed_job = failed_solid_queue_classify(
          job,
          exception_class: "SolidQueue::Processes::ProcessPrunedError"
        )

        result = described_class.enqueue_for_job!(job)

        expect(result.recovered_failed_execution_ids).to be_present
        expect(SolidQueue::Job.where(id: failed_job.id)).to be_empty
        expect(SolidQueue::FailedExecution.where(job_id: failed_job.id)).to be_empty
        expect(SolidQueue::ReadyExecution.joins(:job).where(solid_queue_jobs: {
          class_name: "ClassifyIssueJob",
          concurrency_key: described_class.solid_queue_concurrency_key_for(job.id)
        })).to exist
      end
    end

    it "raises instead of silently reporting success when a failed execution still blocks the key" do
      job = pending_job

      with_solid_queue_adapter do
        failed_job = failed_solid_queue_classify(
          job,
          exception_class: "RuntimeError"
        )

        expect {
          described_class.enqueue_for_job!(job)
        }.to raise_error(described_class::EnqueueBlockedError) { |error|
          expect(error.blocking_solid_queue_job_ids).to contain_exactly(failed_job.id)
          expect(error.concurrency_key).to eq(described_class.solid_queue_concurrency_key_for(job.id))
        }
      end
    end
  end
end
