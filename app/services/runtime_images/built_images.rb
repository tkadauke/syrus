module RuntimeImages
  # Publishes images built on one worker so any other worker can run them,
  # and finds them again by the identity of what was built. Consumer-neutral:
  # callers choose the owner, the source kind, and the source reference.
  #
  # The local engine is only a build and cache location. The durable answer to
  # "has this been built" is a RuntimeImage record whose digest the registry
  # provider has verified, never a tag in one daemon's image store.
  class BuiltImages
    DEFAULT_PLATFORM = "linux/amd64".freeze

    def initialize(service: Service.new, engine: WorkerCache::CliEngine.new, cache: nil, provider_key: OciRegistry::Provider::KEY,
                   supply_chain_scanner: nil)
      @service = service
      @engine = engine
      @cache = cache
      @provider_key = provider_key
      @supply_chain_scanner = supply_chain_scanner
    end

    # True when the provider can store images. Callers that can run without
    # one (a registry is an optional dependency) decide their own fallback.
    def available? = Providers.keys.include?(@provider_key)

    # The newest pullable image published for this source identity, or nil.
    def find(owner_kind:, owner_ref:, source_kind:, source_ref:, platform: DEFAULT_PLATFORM)
      namespace = RuntimeImageNamespace.find_by(owner_kind: owner_kind.to_s, owner_ref: owner_ref.to_s, provider_key: @provider_key)
      return unless namespace
      RuntimeImage.pullable.where(runtime_image_namespace: namespace, source_kind: source_kind.to_s, source_ref: source_ref.to_s, platform: platform)
        .order(published_at: :desc, id: :desc).first
    end

    # Exports the locally built image, publishes it, and returns the durable
    # record. The digest is whatever the provider verified, not a local tag.
    def publish_local(local_reference:, owner_kind:, owner_ref:, source_kind:, source_ref:, source_digest: nil, platform: DEFAULT_PLATFORM, provenance: {})
      payload = @engine.export_oci(local_reference, platform: platform)
      image = @service.publish(
        namespace: namespace_for(owner_kind, owner_ref), source_kind: source_kind.to_s, source_ref: source_ref.to_s,
        source_digest: source_digest, platform: platform, provenance: provenance, payload: payload
      )
      scanner = @supply_chain_scanner || Verifications::SupplyChainScanner.new(built_images: self)
      attempt = Verifications::Orchestrator.new(service: @service, supply_chain_scanner: scanner).verify(image)
      raise Error, "published runtime image #{image.digest} failed verification: #{attempt.failure_code}" unless attempt.accepted?

      image
    end

    # Makes the image local (pulling by digest when this worker lacks it),
    # leases it for the duration of the block, and yields the immutable
    # reference to run.
    def acquire(image, &block)
      worker_cache.acquire(image, &block)
    end

    # Supplies an available image to verification before it is eligible for
    # normal acquisition. WorkerCache still proves the immutable digest.
    def acquire_for_verification(image, &block)
      worker_cache.acquire_for_verification(image, &block)
    end

    # The namespace for an owner identity, created on first use. Callers that
    # submit builds need it before anything has been published.
    def namespace_for(owner_kind, owner_ref)
      identity = { owner_kind: owner_kind.to_s, owner_ref: owner_ref.to_s, provider_key: @provider_key }
      RuntimeImageNamespace.find_by(identity) || RuntimeImageNamespace.create!(identity.merge(name: namespace_name(identity)))
    rescue ActiveRecord::RecordNotUnique
      RuntimeImageNamespace.find_by!(identity)
    end

    private

    def worker_cache
      @cache ||= WorkerCache.new(engine: @engine, service: @service)
    end

    # Namespaces are keyed by the full owner identity plus provider. The name
    # is globally unique, so it carries a digest of that identity: lossy
    # slugs ("repo/a" vs "repo-a") must never share a namespace.
    def namespace_name(identity)
      slug = "#{identity[:owner_kind]}-#{identity[:owner_ref]}".downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
      suffix = Digest::SHA256.hexdigest(identity.values.join("\0"))[0, 12]
      "#{slug[0, 150]}-#{suffix}"
    end
  end
end
