require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe "Runtime Image Service audit, health, and diagnostics" do
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    RuntimeImages::Telemetry.declare_metrics!
    Metrics::RuntimeImageSampler.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }

  def metric_value(instrument, tags)
    instrument.samples.find { |labels, _| labels.symbolize_keys == tags }&.last
  end

  def publish(payload = "a")
    service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "rev-#{payload}", platform: "linux/amd64", payload: payload)
  end

  describe "audit trail" do
    it "records publish, revoke, retain, and delete decisions" do
      image = publish
      service.retain(image, reason: "rollback", until_time: 1.day.ago)
      image.release_retention!
      service.revoke(image, reason: "vulnerable", actor: "admin@example.test")
      service.delete(image)

      events = RuntimeImageAuditEvent.order(:id).pluck(:event_type, :outcome)
      expect(events).to eq([ %w[publish ok], %w[retain ok], %w[revoke ok], %w[delete ok] ])
      expect(RuntimeImageAuditEvent.find_by(event_type: "revoke").actor).to eq("admin@example.test")
    end

    it "audits a failed provider call and re-raises" do
      image = publish
      provider.delete_error = RuntimeImages::ProviderError.new("registry down")
      expect { service.delete(image) }.to raise_error(RuntimeImages::ProviderError)
      event = RuntimeImageAuditEvent.find_by(event_type: "delete")
      expect(event.outcome).to eq("failed")
      expect(event.details["error"]).to include("registry down")
    end

    it "audits authentication failures as their own event" do
      image = publish
      provider.delete_error = RuntimeImages::AuthenticationError.new("bad token")
      expect { service.delete(image) }.to raise_error(RuntimeImages::AuthenticationError)
      expect(RuntimeImageAuditEvent.where(event_type: "auth", outcome: "failed").count).to eq(1)
    end

    it "never lets an audit failure change the operation outcome" do
      allow(RuntimeImageAuditEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      expect(publish).to be_available
    end

    it "counts operations" do
      expect { publish }.to change {
        metric_value(Syrus::Metrics.counter(:syrus_runtime_image_operations_total), { kind: "publish", outcome: "ok" }).to_i
      }.by(1)
    end
  end

  describe RuntimeImages::Health do
    def statuses = described_class.new.checks.to_h { |c| [ c.name, c.status ] }

    before { RuntimeImages::Providers.register(provider) }
    after { RuntimeImages::Providers.unregister(provider.key) }

    it "is healthy with no problems" do
      publish
      expect(described_class.new).to be_ok
      expect(statuses.values.uniq).to eq([ :ok ])
    end

    it "flags failed and exhausted cleanup" do
      image = publish
      image.record_cleanup_failure!(StandardError.new("nope"))
      expect(statuses["image cleanup"]).to eq(:warn)
      image.update!(cleanup_failure_count: RuntimeImages::Collector::MAX_CLEANUP_ATTEMPTS)
      expect(statuses["image cleanup"]).to eq(:fail)
    end

    it "flags corrupt pulls, auth failures, stuck pending images, and unregistered providers" do
      image = publish
      RuntimeImagePullEvent.create!(hostname: "w1", digest: image.digest, outcome: "corrupt", runtime_image: image)
      RuntimeImageAuditEvent.create!(event_type: "auth", outcome: "failed")
      RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'e' * 64}", source_kind: "x", source_ref: "y", created_at: 3.hours.ago)
      RuntimeImageNamespace.create!(name: "other", owner_kind: "k", owner_ref: "2", provider_key: "missing")

      expect(statuses).to include("image integrity" => :fail, "registry authentication" => :fail,
                                  "pending images" => :warn, "providers" => :fail)
    end

    it "warns on registry timeouts and worker disk pressure" do
      image = publish
      RuntimeImagePullEvent.create!(hostname: "w1", digest: image.digest, outcome: "timeout", runtime_image: image)
      expect(statuses["storage"]).to eq(:warn)
    end

    it "summarises retained rollback images, cache footprint, and recent audit events in the snapshot" do
      image = publish
      service.retain(image, reason: "rollback", until_time: 3.days.from_now)
      RuntimeImageCacheEntry.create!(runtime_image: image, hostname: "w1", digest: image.digest, size_bytes: 500)

      snapshot = described_class.new.snapshot

      expect(snapshot[:retained]).to include(count: 1, expiring_soon: 1)
      expect(snapshot[:cache]).to eq([ { hostname: "w1", entries: 1, bytes: 500 } ])
      expect(snapshot[:images]).to eq("available" => 1)
      expect(snapshot[:recent_audit].map { |e| e[:event_type] }).to include("publish", "retain")
    end
  end

  describe Metrics::RuntimeImageSampler do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "samples image states, cache bytes, and pull outcomes into gauges" do
      image = publish
      image.update!(cleanup_failure_count: 1)
      RuntimeImageCacheEntry.create!(runtime_image: image, hostname: "w1", digest: image.digest, size_bytes: 40)
      RuntimeImagePullEvent.create!(hostname: "w1", digest: image.digest, outcome: "hit", runtime_image: image)

      described_class.sample!
      expect(described_class.refresh_gauges!).to be(true)

      expect(metric_value(Syrus::Metrics.gauge(:syrus_runtime_images), { state: "available" })).to eq(1)
      expect(metric_value(Syrus::Metrics.gauge(:syrus_runtime_images), { state: "cleanup_failed" })).to eq(1)
      expect(metric_value(Syrus::Metrics.gauge(:syrus_runtime_image_cache_bytes), { state: "present" })).to eq(40)
      expect(metric_value(Syrus::Metrics.gauge(:syrus_runtime_image_pulls_24h), { outcome: "hit" })).to eq(1)
    end

    it "reports no sample when the cache is empty" do
      expect(described_class.refresh_gauges!).to be(false)
    end
  end

  describe RuntimeImageReconcileJob do
    it "runs on the cleanup queue and reconciles" do
      expect(described_class.new.queue_name).to eq("cleanup")
      RuntimeImages::Providers.register(provider)
      publish
      expect { expect(described_class.perform_now).to eq(0) }
        .to have_enqueued_job(BaseRebuildDiscoveryJob)
    ensure
      RuntimeImages::Providers.unregister(provider.key)
    end
  end
end
