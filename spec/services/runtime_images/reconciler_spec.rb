require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Reconciler do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }

  def publish(payload)
    service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "rev-#{payload}", platform: "linux/amd64", payload: payload)
  end

  def reconcile(**options) = described_class.new(service: service, **options).call

  it "reports nothing when records and provider agree" do
    publish("a")
    expect(reconcile).to be_empty
  end

  it "marks an available record deleted when the provider lost the image" do
    image = publish("a")
    provider.store.clear

    findings = reconcile

    expect(findings.map(&:kind)).to eq([ :missing_in_registry ])
    expect(image.reload).to be_deleted
    expect(RuntimeImageAuditEvent.where(event_type: "reconcile.missing_in_registry", outcome: "repaired")).to exist
  end

  it "only reports when repair is disabled" do
    image = publish("a")
    provider.store.clear

    expect(reconcile(repair: false).first.action).to eq(:none)
    expect(image.reload).to be_available
    expect(RuntimeImageAuditEvent.where(outcome: "detected")).to exist
  end

  it "re-asserts removal of a revoked image the provider still stores" do
    image = publish("a")
    image.mark_revoked!(reason: "bad")
    provider.calls.clear

    findings = reconcile

    expect(findings.map(&:kind)).to eq([ :revoked_still_stored ])
    expect(provider.calls.map(&:first)).to include(:revoke)
  end

  it "resolves stale pending records either way and leaves recent ones alone" do
    present = publish("present")
    present.update_columns(availability: "pending", published_at: nil, created_at: 2.hours.ago)
    gone = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'c' * 64}", source_kind: "x", source_ref: "y", created_at: 2.hours.ago)
    fresh = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'d' * 64}", source_kind: "x", source_ref: "z")

    reconcile

    expect(present.reload).to be_available
    expect(gone.reload).to be_deleted
    expect(fresh.reload).to be_pending
  end

  describe "orphans" do
    before do
      publish("known")
      provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "x", source_ref: "orphan", source_digest: nil,
                                                         platform: "linux/amd64", provenance: {}, payload: "orphan"))
    end

    it "reports a stored digest without a record and does not delete it by default" do
      findings = reconcile
      expect(findings.map(&:kind)).to eq([ :orphan_digest ])
      expect(provider.calls.map(&:first)).not_to include(:delete)
    end

    it "deletes orphans only when asked" do
      findings = reconcile(delete_orphans: true)
      expect(findings.first.action).to eq(:deleted)
      expect(provider.store.keys.size).to eq(1)
    end

    it "keeps going and reports a provider that cannot list" do
      provider.unsupported_listing!
      expect(reconcile.map(&:kind)).to eq([ :listing_unsupported ])
    end
  end

  it "reports an unreachable namespace without aborting the pass" do
    publish("a")
    allow(provider).to receive(:inspect).and_call_original
    allow(provider).to receive(:inspect_image).and_raise(RuntimeImages::AuthenticationError, "denied")

    findings = reconcile

    expect(findings.map(&:kind)).to eq([ :namespace_unreachable ])
  end
end
