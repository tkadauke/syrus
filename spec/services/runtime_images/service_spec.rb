require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Service do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "widget_owner", owner_ref: "42", provider_key: provider.key)
  end
  let(:service) { described_class.new(provider: provider) }

  def publish(payload: "layer-a", **overrides)
    service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "rev-1", platform: "linux/amd64",
                    source_digest: "sha256:#{'a' * 64}", provenance: { "builder" => "synthetic" }, payload: payload, **overrides)
  end

  it "publishes an immutable digest with source identity and provenance" do
    image = publish
    expect(image).to be_available
    expect(image.verification_state).to eq("unverified")
    expect(image).not_to be_pullable
    expect(image.digest).to match(RuntimeImage::DIGEST_FORMAT)
    expect(image.source_kind).to eq("dockerfile")
    expect(image.provenance).to eq("builder" => "synthetic")
    expect(image.published_at).to be_present
    expect { image.update!(digest: "sha256:#{"b" * 64}") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "is idempotent for the same digest and rejects a conflicting source identity" do
    first = publish
    expect(publish).to eq(first)
    expect { publish(source_ref: "rev-2") }.to raise_error(RuntimeImages::Error, /different source identity/)
  end

  it "resolves, inspects, and pulls an available image" do
    image = publish(verification_state: "candidate")
    expect(service.resolve(namespace: namespace, reference: "rev-1", platform: "linux/amd64")).to eq(image)
    expect(service.inspect_image(image).present).to be(true)
    expect(service.pull(image).digest).to eq(image.digest)
  end

  it "raises NotFound when a resolved digest has no durable record" do
    provider.publish(RuntimeImages::PublishRequest.new(namespace: namespace, source_kind: "x", source_ref: "orphan",
                                                       source_digest: nil, platform: "linux/amd64", provenance: {}, payload: "z"))
    expect { service.resolve(namespace: namespace, reference: "orphan", platform: "linux/amd64") }
      .to raise_error(RuntimeImages::NotFound)
  end

  it "revokes before telling the provider and then refuses pulls and republish" do
    image = publish
    service.revoke(image, reason: "vulnerable")
    expect(image.reload).to be_revoked
    expect(image.revoked_reason).to eq("vulnerable")
    expect { service.pull(image) }.to raise_error(RuntimeImages::NotPullable)
    expect { publish }.to raise_error(RuntimeImages::Error, /cannot be republished/)
    expect(provider.calls.map(&:first)).to include(:revoke)
  end

  it "requests termination across workers only for live agents pinned to a severely revoked digest" do
    image = publish(verification_state: "candidate")
    affected = SpawnedProcess.create!(kind: "agent", command: "agent", hostname: "worker-a", pid: 101,
      started_at: Time.current, resource_attribution: { "runtime_image_digest" => image.digest })
    other = SpawnedProcess.create!(kind: "agent", command: "agent", hostname: "worker-b", pid: 102,
      started_at: Time.current, resource_attribution: { "runtime_image_digest" => "sha256:#{'f' * 64}" })
    allow(OperationalLogging).to receive(:ingest)

    service.revoke(image, reason: "critical integrity failure", severity: "severe")

    expect(affected.reload.kill_requested_at).to be_present
    expect(other.reload.kill_requested_at).to be_nil
    expect(RuntimeImageAuditEvent.where(event_type: "revoke.termination").last.details)
      .to include("requested_processes" => 1, "recovery_guidance" => include("promote or roll back"))
  end

  it "does not terminate an existing turn for a standard revocation" do
    image = publish(verification_state: "candidate")
    process = SpawnedProcess.create!(kind: "agent", command: "agent", hostname: "worker-a", pid: 101,
      started_at: Time.current, resource_attribution: { "runtime_image_digest" => image.digest })

    service.revoke(image, reason: "retired", severity: "standard")

    expect(process.reload.kill_requested_at).to be_nil
  end

  it "re-asserts revocation on the provider when a reactivating provider is republished" do
    image = publish
    service.revoke(image, reason: "vulnerable")
    allow(provider).to receive(:publish).and_wrap_original do |m, req|
      m.call(req).tap { provider.store[[image.digest, image.platform]] = { revoked: false } }
    end
    expect { publish }.to raise_error(RuntimeImages::Error, /cannot be republished/)
    expect(provider.store[[image.digest, image.platform]][:revoked]).to be(true)
  end

  it "keeps provider state revoked after republishing a revoked digest" do
    image = publish
    service.revoke(image, reason: "vulnerable")
    expect { publish }.to raise_error(RuntimeImages::Error)
    expect(provider.store[[image.digest, image.platform]][:revoked]).to be(true)
  end

  it "re-asserts revocation even when the republish has a conflicting source identity" do
    image = publish
    service.revoke(image, reason: "vulnerable")
    allow(provider).to receive(:publish).and_wrap_original do |m, req|
      m.call(req).tap { provider.store[[image.digest, image.platform]] = { revoked: false } }
    end
    expect { publish(source_ref: "rev-2") }.to raise_error(RuntimeImages::Error)
    expect(provider.store[[image.digest, image.platform]][:revoked]).to be(true)
  end

  it "re-asserts deletion even when the republish has a conflicting source identity" do
    image = publish
    service.delete(image)
    allow(provider).to receive(:publish).and_wrap_original do |m, req|
      m.call(req).tap { provider.store[[image.digest, image.platform]] = { revoked: false } }
    end
    expect(provider).to receive(:delete).and_call_original
    expect { publish(source_ref: "rev-2") }.to raise_error(RuntimeImages::Error)
  end

  it "keeps a revoked image revoked even when the provider call fails" do
    image = publish
    allow(provider).to receive(:revoke).and_raise(RuntimeImages::ProviderError, "down")
    expect { service.revoke(image, reason: "x") }.to raise_error(RuntimeImages::ProviderError)
    expect(image.reload).to be_revoked
  end

  it "retains an image so it cannot be deleted until retention lapses" do
    image = publish
    service.retain(image, reason: "audit", until_time: 1.day.from_now)
    expect(image.reload.retention_state).to eq("retained")
    expect { service.delete(image) }.to raise_error(RuntimeImages::Error, /retained/)
    image.update!(retain_until: 1.minute.ago)
    expect(RuntimeImage.retention_expired).to include(image)
    service.delete(image)
    expect(image.reload).to be_deleted
    expect(image.deleted_at).to be_present
    expect(provider.calls.map(&:first)).to include(:delete)
  end

  it "does not record a deletion when the provider fails" do
    image = publish
    allow(provider).to receive(:delete).and_raise(RuntimeImages::ProviderError, "down")
    expect { service.delete(image) }.to raise_error(RuntimeImages::ProviderError)
    expect(image.reload).to be_available
  end

  it "looks up the provider from the namespace registry when none is injected" do
    RuntimeImages::Providers.register(provider)
    image = described_class.new.then { |s| s.publish(namespace: namespace, source_kind: "k", source_ref: "r", platform: "linux/arm64", payload: "p") }
    expect(image).to be_available
  ensure
    RuntimeImages::Providers.unregister(provider.key)
  end

  it "reports a missing provider registration" do
    expect { described_class.new.pull(RuntimeImage.new(runtime_image_namespace: namespace, availability: "available", verification_state: "candidate")) }
      .to raise_error(RuntimeImages::NotFound, /no runtime image provider/)
  end
end
