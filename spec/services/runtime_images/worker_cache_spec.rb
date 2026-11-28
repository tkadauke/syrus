require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::WorkerCache do
  # In-memory engine; no container runtime is touched.
  class FakeCacheEngine < RuntimeImages::WorkerCache::Engine
    attr_accessor :usage, :pull_error, :pull_delay, :corrupt, :image_labels
    attr_reader :pulls, :removed

    def initialize
      @images = {}
      @pulls = []
      @removed = []
      @usage = { total_bytes: 1000, free_bytes: 900 }
    end

    def pull(reference, timeout:, auth: nil)
      @pulls << reference
      sleep(pull_delay) if pull_delay
      raise pull_error if pull_error
      @images[reference] = corrupt ? "sha256:#{'f' * 64}" : reference.split("@").last
    end

    def digests(reference) = @images.key?(reference) ? [@images[reference]] : []
    def labels(_reference) = image_labels || {}
    def size_bytes(_reference) = 100
    def remove(reference)
      @removed << reference
      @images.delete(reference)
    end
    def disk_usage = usage
    def drop!(reference) = @images.delete(reference)
  end

  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:engine) { FakeCacheEngine.new }
  let(:cache) { described_class.new(engine: engine, service: service, hostname: "w1", acquire_timeout: 0.2) }

  def publish(payload)
    service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "r-#{payload}", platform: "linux/amd64", payload: payload,
                    verification_state: "candidate")
  end

  def outcomes = RuntimeImagePullEvent.order(:id).pluck(:outcome)

  it "pulls by digest on a miss, verifies, and hits afterwards" do
    image = publish("a")
    first = cache.acquire(image)
    second = cache.acquire(image)
    expect(first.cache_hit).to be(false)
    expect(second.cache_hit).to be(true)
    expect(engine.pulls).to eq([image.locator])
    expect(outcomes).to eq(%w[pulled hit])
    expect(RuntimeImagePullEvent.hit_ratio).to eq(0.5)
  end

  describe "runtime ABI admission" do
    let(:source_digest) { "sha256:#{"a" * 64}" }
    let(:recipe_digest) { "sha256:#{"b" * 64}" }

    def publish_base
      provenance = { "recipe_digest" => recipe_digest,
                     RuntimeImages::RuntimeAbi::ATTESTATION_KEY => RuntimeImages::RuntimeAbi.attest(source_digest: source_digest, recipe_digest: recipe_digest) }
      service.publish(namespace: namespace, source_kind: RuntimeImages::CoworkerBase::SOURCE_KIND, source_ref: "base", platform: "linux/amd64",
                      source_digest: source_digest, provenance: provenance, payload: "base", verification_state: "candidate")
    end

    it "hands out a compatible standard base image" do
      engine.image_labels = RuntimeImages::RuntimeAbi.labels
      image = publish_base
      pulled = cache.acquire(image, provider: "claude")
      expect(pulled.reference).to eq(image.locator)
    end

    it "blocks an incompatible image before it is returned and releases its lease" do
      engine.image_labels = RuntimeImages::RuntimeAbi.labels.merge("io.syrus.runtime-abi.compat-max" => "99")
      image = publish_base
      expect { cache.acquire(image) { raise "launched" } }.to raise_error(RuntimeImages::RuntimeAbi::Incompatible, /label_mismatch|compat-max/)
      expect(RuntimeImageCacheEntry.where(runtime_image: image).first.lease_count).to eq(0)
    end

    it "releases its lease when reading the image's labels fails" do
      image = publish_base
      allow(engine).to receive(:labels).and_raise(RuntimeImages::WorkerCache::EngineError, "inspect failed")

      expect { cache.acquire(image) }.to raise_error(RuntimeImages::WorkerCache::EngineError)
      expect(RuntimeImageCacheEntry.where(runtime_image: image).first.lease_count).to eq(0)
    end

    it "blocks an image carrying no ABI labels" do
      engine.image_labels = {}
      expect { cache.acquire(publish_base) }.to raise_error(RuntimeImages::RuntimeAbi::Incompatible)
    end

    it "does not apply to images that are not the standard base" do
      expect(cache.acquire(publish("plain")).cache_hit).to be(false)
    end

    it "validates a requested custom runtime image for the selected provider" do
      engine.image_labels = RuntimeImages::RuntimeAbi.labels
      image = service.publish(
        namespace: namespace, source_kind: "coworker_environment", source_ref: "custom",
        platform: "linux/amd64", source_digest: source_digest, payload: "custom",
        verification_state: "candidate", provenance: {
          "recipe_digest" => recipe_digest,
          RuntimeImages::RuntimeAbi::ATTESTATION_KEY =>
            RuntimeImages::RuntimeAbi.attest(source_digest: source_digest, recipe_digest: recipe_digest)
        }
      )

      expect { cache.acquire(image, provider: "unknown", validate_runtime_abi: true) }
        .to raise_error(RuntimeImages::RuntimeAbi::Incompatible, /provider_unsupported|provider/)
      expect(RuntimeImageCacheEntry.find_by!(runtime_image: image).lease_count).to eq(0)
    end
  end

  it "rechecks local integrity immediately before handing an image to the launcher" do
    image = publish("a")
    allow(engine).to receive(:digests).with(image.locator)
      .and_return([ image.digest ], [ "sha256:#{"f" * 64}" ])

    expect { cache.acquire(image) { raise "launched" } }
      .to raise_error(RuntimeImages::WorkerCache::CorruptImage, /changed before launch/)
    expect(engine.removed).to eq([ image.locator ])
    expect(RuntimeImageCacheEntry.where(runtime_image: image)).to be_empty
  end

  it "rechecks revocation immediately before handing an image to the launcher" do
    image = publish("a")
    reloads = 0
    allow(image).to receive(:reload).and_wrap_original do |original|
      reloads += 1
      image.update_columns(availability: "revoked", revoked_at: Time.current) if reloads == 3
      original.call
    end

    expect { cache.acquire(image) { raise "launched" } }
      .to raise_error(RuntimeImages::WorkerCache::Revoked, /revoked before launch/)
    expect(RuntimeImageCacheEntry.find_by!(runtime_image: image).lease_count).to eq(0)
  end

  it "does not touch worker capabilities or identity records" do
    expect { cache.acquire(publish("a")) }.not_to change { WorkerHostHealthSample.count }
  end

  it "fails as corrupt, removes the copy, and records no cache entry" do
    image = publish("a")
    engine.corrupt = true
    expect { cache.acquire(image) }.to raise_error(RuntimeImages::WorkerCache::CorruptImage)
    expect(engine.removed).to eq([image.locator])
    expect(RuntimeImageCacheEntry.count).to eq(0)
    expect(outcomes).to eq(%w[corrupt])
  end

  it "re-pulls when a cached copy vanished or no longer matches" do
    image = publish("a")
    cache.acquire(image)
    engine.drop!(image.locator)
    expect(cache.acquire(image).cache_hit).to be(false)
    expect(engine.pulls.size).to eq(2)
  end

  it "records an engine timeout" do
    engine.pull_error = RuntimeImages::WorkerCache::EngineTimeout.new("slow")
    expect { cache.acquire(publish("a")) }.to raise_error(RuntimeImages::WorkerCache::EngineTimeout)
    expect(outcomes).to eq(%w[timeout])
  end

  it "records a registry outage reported by the provider" do
    image = publish("a")
    allow(provider).to receive(:pull).and_raise(RuntimeImages::ProviderError, "registry down")
    expect { cache.acquire(image) }.to raise_error(RuntimeImages::ProviderError)
    expect(outcomes).to eq(%w[registry_unavailable])
    expect(engine.pulls).to be_empty
  end

  it "refuses a revoked digest without pulling and records it" do
    image = publish("a")
    service.revoke(image, reason: "cve")
    expect { cache.acquire(image) }.to raise_error(RuntimeImages::NotPullable)
    expect(engine.pulls).to be_empty
    expect(outcomes).to eq(%w[revoked])
  end

  it "acquires an unverified image only through the verification boundary" do
    image = service.publish(namespace: namespace, source_kind: "dockerfile", source_ref: "unverified", platform: "linux/amd64",
                            payload: "unverified", verification_state: "unverified")

    expect { cache.acquire(image) }.to raise_error(RuntimeImages::NotPullable)
    expect(cache.acquire_for_verification(image) { |reference| reference }).to eq(image.locator)
    expect(engine.digests(image.locator)).to contain_exactly(image.digest)

    image.update!(verification_state: "candidate")
    expect { cache.acquire_for_verification(image) }.to raise_error(RuntimeImages::NotPullable)

    service.revoke(image, reason: "unsafe")
    expect { cache.acquire_for_verification(image) }.to raise_error(RuntimeImages::NotPullable)
  end

  it "bounds concurrent pulls" do
    bounded = described_class.new(engine: engine, service: service, hostname: "w1", max_concurrent_pulls: 1, acquire_timeout: 0.05)
    a = publish("a")
    b = publish("b")
    engine.pull_delay = 0.5
    t = Thread.new { ActiveRecord::Base.connection_pool.with_connection { bounded.acquire(a) } }
    sleep 0.15
    expect { bounded.acquire(b) }.to raise_error(RuntimeImages::WorkerCache::Busy)
    t.join
    expect(outcomes).to include("busy", "pulled")
  end

  describe "eviction" do
    it "enforces the administrator byte ceiling after a pull" do
      bounded = described_class.new(engine: engine, service: service, hostname: "w1", max_bytes: 150)
      first = publish("a")
      second = publish("b")

      bounded.acquire(first) { nil }
      bounded.acquire(second) { nil }

      expect(RuntimeImageCacheEntry.pluck(:digest)).to eq([ second.digest ])
      expect(engine.removed).to eq([ first.locator ])
    end

    it "uses one aggregate query while evicting multiple entries to the byte ceiling" do
      unlimited = described_class.new(engine: engine, service: service, hostname: "w1", max_bytes: 0)
      %w[a b c].each { |payload| unlimited.acquire(publish(payload)) { nil } }
      bounded = described_class.new(engine: engine, service: service, hostname: "w1", max_bytes: 50)
      sums = []
      subscriber = lambda do |*, payload|
        sums << payload[:sql] if payload[:sql].match?(/SUM\(.+size_bytes/i)
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        bounded.send(:enforce_byte_ceiling!)
      end

      expect(sums.size).to eq(1)
      expect(RuntimeImageCacheEntry.count).to eq(0)
    end

    it "purges entries that exceeded the unused retention window" do
      now = Time.current
      retained = described_class.new(engine: engine, service: service, hostname: "w1", unused_retention_hours: 2, clock: -> { now })
      stale = publish("stale")
      current = publish("current")
      retained.acquire(stale) { nil }
      now += 3.hours

      retained.acquire(current) { nil }

      expect(RuntimeImageCacheEntry.pluck(:digest)).to eq([ current.digest ])
      expect(engine.removed).to eq([ stale.locator ])
    end

    it "evicts least recently used first and never a leased entry" do
      images = %w[a b c].map { |p| publish(p) }
      images.each { |i| cache.acquire(i) { nil } }
      RuntimeImageCacheEntry.find_by(digest: images[0].digest).update!(last_used_at: 3.hours.ago)
      RuntimeImageCacheEntry.find_by(digest: images[1].digest).update!(last_used_at: 2.hours.ago)
      RuntimeImageCacheEntry.find_by(digest: images[2].digest).update!(last_used_at: 1.hour.ago)
      RuntimeImageCacheEntry.find_by(digest: images[0].digest).update!(leased_until: 1.hour.from_now)

      expect(cache.evict(target_bytes: 200)).to eq([images[1].digest])
      expect(engine.removed).to eq([images[1].locator])
      expect(cache.evict(target_bytes: 0)).to eq([images[2].digest])
      expect(RuntimeImageCacheEntry.pluck(:digest)).to eq([images[0].digest])
    end

    it "evicts revoked images first and purges them on demand" do
      good = publish("a")
      bad = publish("b")
      cache.acquire(good) { nil }
      cache.acquire(bad) { nil }
      service.revoke(bad, reason: "cve")
      expect(cache.purge_revoked).to eq([bad.digest])
      expect(RuntimeImageCacheEntry.pluck(:digest)).to eq([good.digest])
    end

    it "relieves pressure only when pressure is not ok" do
      cache.acquire(publish("a")) { nil }
      expect(cache.relieve_pressure!).to eq([])
      engine.usage = { total_bytes: 1000, free_bytes: 50 }
      expect(cache.pressure[:level]).to eq("critical")
      expect(cache.relieve_pressure!(fraction: 0).size).to eq(1)
    end
  end

  describe "leases" do
    it "keeps an entry protected until every overlapping holder releases, including non-block acquires" do
      image = publish("a")
      first = cache.acquire(image)
      second = cache.acquire(image)
      cache.release(first.entry)
      expect(cache.evict(target_bytes: 0)).to eq([])
      cache.release(second.entry)
      expect(RuntimeImageCacheEntry.first).to have_attributes(lease_count: 0, leased_until: nil)
      expect(cache.evict(target_bytes: 0)).to eq([image.digest])
    end

    # formal/SyrusModel/CacheLease.lean: a holder whose lease expired must not
    # release the lease a later acquisition started over, or eviction removes
    # an image the later holder is still using.
    it "does not let a holder whose lease expired release a later holder's fresh lease" do
      now = Time.current
      clocked = described_class.new(engine: engine, service: service, hostname: "w1", acquire_timeout: 0.2,
                                    lease_seconds: 60, clock: -> { now })
      image = publish("a")
      stale = clocked.acquire(image)
      now += 61 # the first holder outlives its lease
      fresh = clocked.acquire(image)

      clocked.release(stale.entry)

      expect(clocked.evict(target_bytes: 0)).to eq([])
      clocked.release(fresh.entry)
      expect(clocked.evict(target_bytes: 0)).to eq([image.digest])
    end

    it "protects an entry from eviction while a block-form holder overlaps a released one" do
      image = publish("a")
      held = cache.acquire(image)
      cache.acquire(image) { expect(cache.evict(target_bytes: 0)).to eq([]) }
      expect(cache.evict(target_bytes: 0)).to eq([])
      cache.release(held.entry)
      expect(cache.evict(target_bytes: 0)).to eq([image.digest])
    end
  end

  describe "lease and eviction atomicity" do
    it "does not remove an entry that was leased after eviction picked it as a candidate" do
      image = publish("a")
      stale = cache.acquire(image) { |_| RuntimeImageCacheEntry.first }
      held = cache.acquire(image)
      expect(cache.send(:remove_entry, stale)).to be(false)
      expect(engine.removed).to be_empty
      expect(RuntimeImageCacheEntry.first).to have_attributes(state: "present", lease_count: 1)
      cache.release(held.entry)
    end

    it "pulls again when eviction claims the entry between ensure_local and the lease" do
      image = publish("a")
      cache.acquire(image) { nil }
      evicted = false
      original = cache.method(:ensure_local)
      allow(cache).to receive(:ensure_local) do |*args, **kw|
        result = original.call(*args, **kw)
        unless evicted
          evicted = true
          expect(cache.evict(target_bytes: 0)).to eq([image.digest])
        end
        result
      end
      pulled = cache.acquire(image)
      expect(pulled.cache_hit).to be(false)
      expect(RuntimeImageCacheEntry.first).to have_attributes(state: "present", lease_count: 1)
      expect(cache.evict(target_bytes: 0)).to eq([])
    end

    it "waits for an in-progress eviction instead of re-promoting the claimed entry" do
      image = publish("a")
      cache.acquire(image) { nil }
      acquired = nil
      waits = 0
      waiter = described_class.new(engine: engine, service: service, hostname: "w1", acquire_timeout: 5,
                                   sleeper: lambda { |_|
                                     waits += 1
                                     # Eviction's engine removal finishes while the acquirer waits.
                                     RuntimeImageCacheEntry.where(state: "evicting").delete_all
                                   })
      allow(engine).to receive(:remove).and_wrap_original do |m, ref|
        m.call(ref)
        acquired = waiter.acquire(image)
        expect(RuntimeImageCacheEntry.count).to eq(1)
        nil
      end
      # The sleeper resolved the claim itself, so the original owner is fenced
      # (its token-scoped delete matches nothing) and reports no eviction.
      expect(cache.evict(target_bytes: 0)).to eq([])
      expect(waits).to eq(1)
      expect(acquired.cache_hit).to be(false)
      expect(engine.pulls.size).to eq(2)
      expect(RuntimeImageCacheEntry.first).to have_attributes(state: "present", lease_count: 1)
    end

    it "times out as busy when an eviction claim never resolves" do
      image = publish("a")
      cache.acquire(image) { nil }
      RuntimeImageCacheEntry.update_all(state: "evicting")
      stuck = described_class.new(engine: engine, service: service, hostname: "w1", acquire_timeout: 0.01, sleeper: ->(_) { sleep 0.02 })
      expect { stuck.acquire(image) }.to raise_error(RuntimeImages::WorkerCache::Busy)
    end

    it "recovers a claim abandoned by a crashed process once it is stale" do
      image = publish("a")
      cache.acquire(image) { nil }
      RuntimeImageCacheEntry.update_all(state: "evicting", updated_at: 10.minutes.ago)
      pulled = cache.acquire(image)
      expect(engine.removed.size).to eq(1)
      expect(pulled.cache_hit).to be(false)
      expect(RuntimeImageCacheEntry.first).to have_attributes(state: "present", lease_count: 1)
    end

    it "fences the original eviction owner once its claim was taken over" do
      image = publish("a")
      cache.acquire(image) { nil }
      RuntimeImageCacheEntry.update_all(updated_at: 10.minutes.ago)
      entry = RuntimeImageCacheEntry.first
      # The original owner's removal is paused; during it the claim goes stale
      # and another process takes it over, which invalidates the owner's token.
      allow(engine).to receive(:remove).and_wrap_original do |original, reference|
        RuntimeImageCacheEntry.where(id: entry.id).update_all(updated_at: 10.minutes.ago)
        taker = described_class.new(engine: FakeCacheEngine.new, service: service, hostname: "w1")
        taker.send(:reconcile_abandoned_claim, RuntimeImageCacheEntry.find(entry.id))
        original.call(reference)
      end
      RuntimeImageCacheEntry.where(id: entry.id).update_all(state: "present")
      expect(cache.evict(target_bytes: 0)).to eq([])
      expect(RuntimeImageCacheEntry.where(id: entry.id)).to be_empty
    end

    it "rejects a claim TTL that does not exceed the engine removal bound" do
      expect { described_class.new(engine: engine, service: service, hostname: "w1", claim_ttl: 60) }
        .to raise_error(ArgumentError, /claim_ttl/)
    end

    it "does not take over a fresh eviction claim" do
      image = publish("a")
      cache.acquire(image) { nil }
      RuntimeImageCacheEntry.update_all(state: "evicting", updated_at: Time.current)
      expect { cache.acquire(image) }.to raise_error(RuntimeImages::WorkerCache::Busy)
      expect(engine.removed).to be_empty
    end

    it "restores the entry when the engine fails to remove it" do
      image = publish("a")
      cache.acquire(image) { nil }
      allow(engine).to receive(:remove).and_raise(RuntimeImages::WorkerCache::EngineError, "busy")
      expect(cache.evict(target_bytes: 0)).to eq([])
      expect(RuntimeImageCacheEntry.first.state).to eq("present")
    end
  end

  describe "#inventory and #pressure" do
    it "reports held digests and disk pressure" do
      image = publish("a")
      cache.acquire(image)
      expect(cache.inventory.first).to include(digest: image.digest, state: "present", size_bytes: 100, leased: true)
      expect(cache.pressure).to include(used_percent: 10.0, level: "ok", cache_bytes: 100)
      engine.usage = { total_bytes: 1000, free_bytes: 150 }
      expect(cache.pressure[:level]).to eq("high")
    end
  end

  describe "#prefetch" do
    it "warms the cache without leasing or counting as a use" do
      image = publish("a")
      results = cache.prefetch([image])
      expect(results.map(&:outcome)).to eq(%w[ready])
      entry = RuntimeImageCacheEntry.first
      expect(entry).to have_attributes(prefetched: true, last_used_at: nil, leased_until: nil)
      expect(RuntimeImagePullEvent.last).to have_attributes(prefetch: true)
      expect(cache.acquire(image).cache_hit).to be(true)
      expect(entry.reload.prefetched).to be(false)
    end

    it "skips under pressure, skips revoked images, and swallows failures" do
      a = publish("a")
      b = publish("b")
      service.revoke(b, reason: "x")
      expect(cache.prefetch([b]).map(&:outcome)).to eq(%w[skipped_not_pullable])
      engine.pull_error = RuntimeImages::WorkerCache::EngineError.new("boom")
      expect(cache.prefetch([a]).map(&:outcome)).to eq(%w[failed])
      engine.pull_error = nil
      engine.usage = { total_bytes: 1000, free_bytes: 100 }
      expect(cache.prefetch([a]).map(&:outcome)).to eq(%w[skipped_pressure])
    end
  end
end
