require "rails_helper"
require "support/synthetic_runtime_image_provider"

# Recovery of the build plane: lost workers, overdue attempts, orphaned
# requests, duplicate deliveries and submissions, and cancellation racing a
# failure.
RSpec.describe RuntimeImages::Builds::Orchestrator, "recovery" do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:orchestrator) { described_class.new }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "e" * 40) }
  let(:config) { RuntimeImages::Builds::Config }

  before { RuntimeImages::Builds.builder = double("builder") }
  after { RuntimeImages::Builds.builder = nil }

  def submit = orchestrator.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "1")

  def counter(name, tags)
    RuntimeImages::Builds::Telemetry # declares the metrics
    Syrus::Metrics.counter(name).samples.find { |labels, _| labels.symbolize_keys == tags }&.last.to_i
  end

  describe "worker loss and stale attempts" do
    it "requeues an attempt whose worker stopped heartbeating, with backoff" do
      request = submit
      _, attempt = orchestrator.claim_next
      later = attempt.lease_expires_at + 1.minute

      reaped = orchestrator.reap_expired(now: later)

      expect(reaped).to eq([ attempt ])
      expect(attempt.reload).to have_attributes(state: "failed", error_code: "lease_expired", retryable: true)
      expect(request.reload).to be_queued
      expect(request.next_attempt_at).to be > later
    end

    it "reaps an attempt that outlived the runtime ceiling even though its lease keeps being renewed" do
      request = submit
      _, attempt = orchestrator.claim_next
      overdue = attempt.started_at + config.max_attempt_runtime + 1.minute
      orchestrator.heartbeat(attempt, now: overdue)

      expect(RuntimeImageBuildAttempt.lease_expired(overdue)).to be_empty
      orchestrator.reap_expired(now: overdue)

      expect(attempt.reload.error_code).to eq("attempt_deadline_exceeded")
      expect(request.reload).to be_queued
    end

    it "does not reap a healthy attempt" do
      submit
      _, attempt = orchestrator.claim_next
      expect(orchestrator.reap_expired(now: attempt.started_at + 1.minute)).to be_empty
    end

    it "fails the request once the attempts are used up" do
      request = submit
      request.update!(max_attempts: 1)
      _, attempt = orchestrator.claim_next
      orchestrator.reap_expired(now: attempt.lease_expires_at + 1.second)

      expect(request.reload).to be_failed
      expect(request.result.error_code).to eq("lease_expired")
    end

    it "lets a late result from a reaped attempt change nothing" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.reap_expired(now: attempt.lease_expires_at + 1.second)

      expect(orchestrator.fail_attempt(attempt, code: "x", detail: "late", retryable: false)).to be_nil
      expect(orchestrator.begin_verifying(attempt)).to be(false)
      expect(request.reload).to be_queued
    end

    it "counts recoveries" do
      submit
      _, attempt = orchestrator.claim_next
      expect { orchestrator.reap_expired(now: attempt.lease_expires_at + 1.second) }
        .to change { counter(:syrus_runtime_image_build_recoveries_total, { reason: "lease_expired" }) }.by(1)
    end
  end

  describe "orphaned requests" do
    it "requeues an in-flight request that lost its attempt" do
      request = submit
      orchestrator.claim_next
      request.attempts.update_all(state: "failed")

      repaired = orchestrator.reap_orphans

      expect(repaired).to eq([ request ])
      expect(request.reload).to be_queued
      expect(RuntimeImageAuditEvent.where(event_type: "build.recovered")).to exist
    end

    it "fails an orphan with no attempts left" do
      request = submit
      orchestrator.claim_next
      request.attempts.update_all(state: "failed")
      request.update!(max_attempts: 1)

      orchestrator.reap_orphans

      expect(request.reload).to be_failed
      expect(request.result.error_code).to eq("orphaned_request")
    end

    it "completes a cancellation nobody finished" do
      request = submit
      orchestrator.claim_next
      request.attempts.update_all(state: "failed")
      request.update!(cancel_requested_at: Time.current)

      orchestrator.reap_orphans

      expect(request.reload).to be_canceled
    end

    it "leaves a request with an active attempt alone" do
      submit
      orchestrator.claim_next
      expect(orchestrator.reap_orphans).to be_empty
    end

    it "is part of the recovery pass the dispatcher runs" do
      request = submit
      orchestrator.claim_next
      request.attempts.update_all(state: "failed")

      expect(orchestrator.recover[:orphans]).to eq([ request ])
    end
  end

  describe "cancellation" do
    it "cancels instead of retrying when the lease of a cancel-requested attempt expires" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.cancel(request, reason: "operator")
      orchestrator.reap_expired(now: attempt.lease_expires_at + 1.second)

      expect(request.reload).to be_canceled
      expect(request.result.outcome).to eq("canceled")
    end

    it "ignores a cancel for a request that already finished" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.fail_attempt(attempt, code: "x", detail: "m", retryable: false)

      expect(orchestrator.cancel(request)).to be_failed
    end
  end

  describe "duplicate requests" do
    it "runs one attempt per delivery however many times the job is delivered" do
      submit
      _, attempt = orchestrator.claim_next

      expect(orchestrator.begin_execution(attempt)).to be(true)
      expect { expect(orchestrator.begin_execution(attempt)).to be(false) }
        .to change { counter(:syrus_runtime_image_build_recoveries_total, { reason: "duplicate_delivery" }) }.by(1)
    end

    it "does not execute an attempt that is no longer active" do
      submit
      _, attempt = orchestrator.claim_next
      orchestrator.fail_attempt(attempt, code: "x", detail: "m", retryable: false)

      expect(orchestrator.begin_execution(attempt)).to be(false)
    end

    it "returns the live request for a duplicate submit and counts it" do
      first = submit
      expect { expect(submit).to eq(first) }
        .to change { counter(:syrus_runtime_image_build_recoveries_total, { reason: "duplicate_submit" }) }.by(1)
      expect(RuntimeImageBuildRequest.count).to eq(1)
    end

    it "does not claim one request twice" do
      request = submit
      expect(orchestrator.claim(request.id)).to be_present
      expect(orchestrator.claim(request.id)).to be_nil
      expect(request.attempts.count).to eq(1)
    end
  end

  describe "slow retry classes" do
    it "backs quota exhaustion and registry trouble off further than an ordinary failure" do
      expect(config.retry_delay(1, code: "quota_exhausted")).to be > config.retry_delay(1, code: "registry_unavailable")
      expect(config.retry_delay(1, code: "registry_unavailable")).to be > config.retry_delay(1)
      expect(config.retry_delay(2, code: "quota_exhausted")).to eq(config.retry_delay(1, code: "quota_exhausted") * 2)
    end

    it "applies the class backoff when the attempt fails" do
      request = submit
      _, attempt = orchestrator.claim_next
      now = Time.current
      orchestrator.fail_attempt(attempt, code: "quota_exhausted", detail: "full", retryable: true, now: now)

      expect(request.reload.next_attempt_at).to be_within(1.second).of(now + config.retry_delay(1, code: "quota_exhausted"))
    end
  end

  describe "telemetry" do
    it "folds unknown error codes into a bounded tag" do
      expect { RuntimeImages::Builds::Telemetry.attempt("failed", "made_up_#{SecureRandom.hex(3)}") }
        .to change { counter(:syrus_runtime_image_build_attempts_total, { outcome: "failed", reason: "other" }) }.by(1)
    end
  end
end
