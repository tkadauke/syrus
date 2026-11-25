require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Builds::Orchestrator do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:orchestrator) { described_class.new }
  let(:builder) { double("builder") }
  let(:revision) { "a" * 40 }

  before { RuntimeImages::Builds.builder = builder }
  after { RuntimeImages::Builds.builder = nil }

  def capture(revision: self.revision, ref: "git://repo")
    RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: ref, revision: revision)
  end

  def submit(ns: namespace, source: capture, recipe: { "dockerfile" => "Dockerfile" }, platform: "linux/amd64")
    orchestrator.submit(namespace: ns, source: source, recipe: recipe, platform: platform, requester_kind: "test", requester_ref: "1")
  end

  def image_for(request)
    RuntimeImages::Service.new(provider: provider).publish(
      namespace: namespace, source_kind: "git", source_ref: "r#{request.id}", platform: "linux/amd64", payload: "p#{request.id}"
    )
  end

  describe "submit" do
    it "queues a request with an immutable source capture and recipe digest" do
      request = submit

      expect(request).to be_queued
      expect(request.source_digest).to match(RuntimeImage::DIGEST_FORMAT)
      expect(request.source_manifest["revision"]).to eq(revision)
      expect { request.update!(source_digest: "sha256:#{"1" * 64}") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(RuntimeImageAuditEvent.where(event_type: "build.queued")).to exist
    end

    it "deduplicates a live request for the same tuple" do
      first = submit
      expect(submit(recipe: { "dockerfile" => "Dockerfile" })).to eq(first)
      expect(RuntimeImageBuildRequest.count).to eq(1)
    end

    it "treats a different source, recipe, platform, or namespace as a different tuple" do
      base = submit
      other_ns = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: provider.key)
      others = [ submit(source: capture(revision: "b" * 40)), submit(recipe: { "dockerfile" => "Other" }),
                 submit(platform: "linux/arm64"), submit(ns: other_ns) ]

      expect(([ base ] + others).map(&:id).uniq.size).to eq(5)
    end

    it "is independent of recipe key order" do
      expect(submit(recipe: { "a" => 1, "b" => 2 })).to eq(submit(recipe: { "b" => 2, "a" => 1 }))
    end

    it "returns the existing request when a concurrent submitter wins the unique index" do
      winner = submit
      allow(RuntimeImageBuildRequest).to receive(:live).and_return(RuntimeImageBuildRequest.none, RuntimeImageBuildRequest.live)
      expect(submit).to eq(winner)
    end

    it "returns the finished request while its image is pullable, and rebuilds once it is revoked" do
      request = submit
      _, attempt = orchestrator.claim_next
      image = image_for(request)
      orchestrator.begin_verifying(attempt)
      orchestrator.succeed(attempt, image: image)

      expect(submit).to eq(request)

      image.mark_revoked!(reason: "bad")
      rebuilt = submit
      expect(rebuilt).not_to eq(request)
      expect(rebuilt).to be_queued
    end

    it "starts a fresh request after a failure" do
      failed = submit
      _, attempt = orchestrator.claim_next
      orchestrator.fail_attempt(attempt, code: "x", detail: "boom", retryable: false)

      expect(failed.reload).to be_failed
      expect(submit).not_to eq(failed)
    end

    it "records a mutable source revision as rejected with a terminal result" do
      expect { capture(revision: "main") }.to raise_error(RuntimeImages::Builds::Rejected) { |e| expect(e.code).to eq("source_not_immutable") }
    end

    it "rejects an unsupported platform and an oversized recipe without queueing them" do
      platform = submit(platform: "plan9/386")
      big = submit(recipe: { "blob" => "x" * 70.kilobytes })

      expect([ platform, big ]).to all(be_rejected)
      expect(platform.result.error_code).to eq("platform_unsupported")
      expect(big.result.error_code).to eq("recipe_too_large")
      expect(RuntimeImageBuildRequest.startable).to be_empty
      expect(platform.active_dedup_key).to be_nil
    end
  end

  describe "claiming and concurrency" do
    it "claims nothing when no builder is registered" do
      RuntimeImages::Builds.builder = nil
      submit
      expect(orchestrator.claim_next).to be_nil
    end

    it "moves a request to building and numbers the attempt" do
      submit
      request, attempt = orchestrator.claim_next(worker: "w1")

      expect(request).to be_building
      expect(attempt).to have_attributes(number: 1, state: "building", worker_hostname: "w1")
      expect(request.attempts_count).to eq(1)
      expect(orchestrator.claim(request.id)).to be_nil
    end

    it "enforces the global concurrency cap" do
      allow(RuntimeImages::Builds::Config).to receive(:max_concurrent_builds).and_return(1)
      other_ns = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: provider.key)
      submit
      submit(ns: other_ns)

      expect(orchestrator.claim_next).not_to be_nil
      expect(orchestrator.claim_next).to be_nil
    end

    # Two dispatch runs can overlap (the recurring job only skips while one is
    # pending). Claims in different namespaces each hold only their own
    # namespace's lock, so the global cap must be checked under a lock every
    # claim takes (formal/SyrusModel/BuildAdmission.lean).
    it "checks the global cap under the instance-wide admission lock" do
      submit
      held = nil
      allow(orchestrator).to receive(:capacity_exhausted?).and_wrap_original do |original, *args|
        held = Syrus::LockOrder::Checker.holds?(AppSetting.current)
        original.call(*args)
      end

      expect(orchestrator.claim_next).not_to be_nil
      expect(held).to be(true)
    end

    it "enforces the per-namespace cap while letting other namespaces proceed" do
      other_ns = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: provider.key)
      submit
      submit(source: capture(revision: "b" * 40))
      theirs = submit(ns: other_ns)

      first, = orchestrator.claim_next
      second, = orchestrator.claim_next

      expect(first.runtime_image_namespace).to eq(namespace)
      expect(second).to eq(theirs)
      expect(orchestrator.claim_next).to be_nil
    end
  end

  describe "state transitions" do
    it "walks queued -> building -> verifying -> succeeded and writes the result" do
      request = submit
      _, attempt = orchestrator.claim_next
      expect(orchestrator.begin_verifying(attempt)).to be(true)
      expect(request.reload).to be_verifying

      result = orchestrator.succeed(attempt, image: image_for(request))

      expect(request.reload).to be_succeeded
      expect(request.active_dedup_key).to be_nil
      expect(attempt.reload.state).to eq("succeeded")
      expect(result).to have_attributes(outcome: "succeeded", attempts_used: 1)
      expect(result.runtime_image).to be_present
    end

    it "gives cancellation precedence when it lands just before success" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.begin_verifying(attempt)
      orchestrator.cancel(request, reason: "stop")

      result = orchestrator.succeed(attempt, image: image_for(request))

      expect(request.reload).to be_canceled
      expect(attempt.reload.state).to eq("canceled")
      expect(result.outcome).to eq("canceled")
    end

    it "rejects illegal transitions" do
      request = submit
      expect { request.transition_to!("succeeded") }.to raise_error(RuntimeImageBuildRequest::InvalidTransition)
      request.transition_to!("canceled")
      expect { request.transition_to!("queued") }.to raise_error(RuntimeImageBuildRequest::InvalidTransition)
    end

    it "ignores late completions for a request that is no longer in flight" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.fail_attempt(attempt, code: "x", detail: "boom", retryable: false)

      expect(orchestrator.succeed(attempt, image: image_for(request))).to eq(request.reload.result)
      expect(request).to be_failed
    end
  end

  describe "bounded retries" do
    it "re-queues a retryable failure with backoff, then fails once attempts run out" do
      request = submit
      request.update!(max_attempts: 2)
      now = Time.current

      _, attempt = orchestrator.claim_next(now: now)
      orchestrator.fail_attempt(attempt, code: "infra", detail: "flaky", retryable: true, now: now)
      expect(request.reload).to be_queued
      expect(request.next_attempt_at).to be > now
      expect(orchestrator.claim_next(now: now)).to be_nil

      _, second = orchestrator.claim_next(now: request.next_attempt_at + 1)
      expect(second.number).to eq(2)
      orchestrator.fail_attempt(second, code: "infra", detail: "flaky", retryable: true)

      expect(request.reload).to be_failed
      expect(request.result).to have_attributes(outcome: "failed", error_code: "infra", attempts_used: 2)
      expect(request.attempts.map(&:state)).to eq(%w[failed failed])
    end

    it "does not retry a non-retryable failure" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.fail_attempt(attempt, code: "bad", detail: "nope", retryable: false)
      expect(request.reload).to be_failed
    end

    it "retries attempts whose lease expired" do
      request = submit
      _, attempt = orchestrator.claim_next
      expect(orchestrator.reap_expired).to be_empty

      reaped = orchestrator.reap_expired(now: attempt.lease_expires_at + 1)

      expect(reaped).to eq([ attempt ])
      expect(attempt.reload).to have_attributes(state: "failed", error_code: "lease_expired", retryable: true)
      expect(request.reload).to be_queued
    end

    it "extends the lease on heartbeat" do
      submit
      _, attempt = orchestrator.claim_next
      original_lease = attempt.lease_expires_at
      expect(orchestrator.heartbeat(attempt, now: original_lease + 5.minutes)).to be(true)
      expect(orchestrator.reap_expired(now: original_lease)).to be_empty
    end
  end

  describe "cancellation" do
    it "cancels a queued request immediately" do
      request = submit
      orchestrator.cancel(request, reason: "not needed")

      expect(request.reload).to be_canceled
      expect(request.result).to have_attributes(outcome: "canceled", message: "not needed")
      expect(request.active_dedup_key).to be_nil
    end

    it "flags an in-flight request and completes when the attempt acknowledges" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.cancel(request)

      expect(request.reload).to be_building
      expect(orchestrator.cancel_requested?(request)).to be(true)
      orchestrator.acknowledge_cancel(attempt)
      expect(request.reload).to be_canceled
      expect(attempt.reload.state).to eq("canceled")
    end

    it "does not retry a failed attempt of a request that was canceled meanwhile" do
      request = submit
      _, attempt = orchestrator.claim_next
      orchestrator.cancel(request)
      orchestrator.fail_attempt(attempt, code: "infra", detail: "flaky", retryable: true)
      expect(request.reload).to be_canceled
    end

    it "is a no-op for a terminal request" do
      request = submit
      orchestrator.cancel(request)
      expect { orchestrator.cancel(request) }.not_to change { RuntimeImageBuildResult.count }
    end
  end
end
