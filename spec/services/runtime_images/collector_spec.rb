require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Collector do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:window) { 30.days }

  def publish(payload, age: 60.days)
    image = service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "rev-#{payload}",
                            platform: "linux/amd64", payload: payload, verification_state: "candidate")
    image.update_columns(published_at: age.ago)
    image
  end

  def collect(**options) = described_class.new(service: service, global_window: window, **options).call

  it "revokes then deletes expired images but keeps the newest pullable image" do
    old = publish("old", age: 90.days)
    newest = publish("new", age: 60.days)

    result = collect

    expect(result.deleted).to eq(1)
    expect(old.reload).to be_deleted
    expect(old.revoked_at).to be_present
    expect(newest.reload).to be_available
    expect(provider.calls.map(&:first)).to include(:revoke, :delete)
    expect(provider.calls.map(&:first).index(:revoke)).to be < provider.calls.map(&:first).index(:delete)
    expect(RuntimeImageAuditEvent.where(event_type: "gc.delete", outcome: "ok", runtime_image_id: old.id)).to exist
  end

  it "never collects an image under an active retention hold and expires lapsed holds" do
    held = publish("held", age: 90.days)
    lapsed = publish("lapsed", age: 90.days)
    publish("keep-newest", age: 1.day)
    service.retain(held, reason: "rollback", until_time: 10.days.from_now)
    service.retain(lapsed, reason: "rollback", until_time: 1.day.ago)

    collect

    expect(held.reload).to be_available
    expect(lapsed.reload).to be_deleted
    expect(RuntimeImageAuditEvent.where(event_type: "retention.expire", runtime_image_id: lapsed.id)).to exist
  end

  it "honours a namespace retention override" do
    short = publish("short", age: 10.days)
    publish("newest", age: 1.day)
    namespace.update!(retention_days: 5)

    collect

    expect(short.reload).to be_deleted
  end

  it "does not collect when the global window is infinite and no override applies" do
    old = publish("old", age: 400.days)
    publish("newest", age: 1.day)
    described_class.new(service: service, global_window: nil).call
    expect(old.reload).to be_available
  end

  it "skips an image a worker currently leases" do
    old = publish("old", age: 90.days)
    publish("newest", age: 1.day)
    RuntimeImageCacheEntry.create!(runtime_image: old, hostname: "w1", digest: old.digest, leased_until: 1.hour.from_now, lease_count: 1)

    result = collect

    expect(result.skipped).to eq(1)
    expect(old.reload).to be_available
    expect(provider.calls.map(&:first)).not_to include(:revoke)
  end

  it "leaves a revoked record and records the failure when the provider delete fails, then retries" do
    old = publish("old", age: 90.days)
    publish("newest", age: 1.day)
    provider.delete_error = RuntimeImages::ProviderError.new("registry down")

    result = collect

    expect(result.failed).to eq(1)
    old.reload
    expect(old).to be_revoked
    expect(old.cleanup_failure_count).to eq(1)
    expect(old.cleanup_last_error).to include("registry down")

    provider.delete_error = nil
    expect(collect.deleted).to eq(1)
    expect(old.reload).to be_deleted
  end

  it "stops retrying an image after the attempt budget" do
    old = publish("old", age: 90.days)
    publish("newest", age: 1.day)
    old.update_columns(cleanup_failure_count: described_class::MAX_CLEANUP_ATTEMPTS)

    expect(collect.skipped).to eq(1)
    expect(old.reload).to be_available
  end

  it "reports a backlog when more candidates remain than the batch size" do
    3.times { |i| publish("old#{i}", age: (90 + i).days) }
    publish("newest", age: 1.day)
    result = collect(batch: 2)
    expect(result.deleted).to eq(2)
    expect(result.backlog).to be(true)
  end

  describe "retention policy wiring" do
    it "registers the policies and runs the executor through the shared registry" do
      keys = RetentionPolicyRegistry.definitions.map(&:key)
      expect(keys).to include(:runtime_image, :runtime_image_verification_evidence, :runtime_image_pull_event, :runtime_image_audit_event)
      expect { RetentionPolicyRegistry.validate! }.not_to raise_error

      old = publish("old", age: 90.days)
      publish("newest", age: 1.day)
      allow(RuntimeImages::Service).to receive(:new).and_return(service)
      result = RetentionPolicyRegistry.fetch(:runtime_image).executor.call
      expect(result.deleted_count).to eq(1)
      expect(old.reload).to be_deleted
    end


    it "prunes superseded verification evidence but always retains the latest attestation" do
      image = publish("verified", age: 1.day)
      attributes = { image_digest: image.digest, state: "accepted", decision: "candidate", policy_snapshot: {},
                     policy_digest: "sha256:#{"a" * 64}", started_at: 201.days.ago }
      old = image.runtime_image_verification_attempts.create!(**attributes, number: 1, finished_at: 200.days.ago)
      latest = image.runtime_image_verification_attempts.create!(**attributes, number: 2, finished_at: 190.days.ago)

      RetentionPolicyRegistry.fetch(:runtime_image_verification_evidence).executor.call

      expect(RuntimeImageVerificationAttempt.exists?(old.id)).to be(false)
      expect(RuntimeImageVerificationAttempt.exists?(latest.id)).to be(true)
    end

    it "prunes old pull and audit events through the generic executor" do
      old = RuntimeImagePullEvent.create!(hostname: "w1", digest: "sha256:#{'a' * 64}", outcome: "hit", created_at: 90.days.ago)
      fresh = RuntimeImagePullEvent.create!(hostname: "w1", digest: "sha256:#{'a' * 64}", outcome: "hit")
      RetentionPolicyRegistry.fetch(:runtime_image_pull_event).executor.call
      expect(RuntimeImagePullEvent.exists?(old.id)).to be(false)
      expect(RuntimeImagePullEvent.exists?(fresh.id)).to be(true)

      old_audit = RuntimeImageAuditEvent.create!(event_type: "delete", outcome: "ok", occurred_at: 400.days.ago)
      fresh_audit = RuntimeImageAuditEvent.create!(event_type: "delete", outcome: "ok")
      RetentionPolicyRegistry.fetch(:runtime_image_audit_event).executor.call
      expect(RuntimeImageAuditEvent.exists?(old_audit.id)).to be(false)
      expect(RuntimeImageAuditEvent.exists?(fresh_audit.id)).to be(true)
    end
  end
end
