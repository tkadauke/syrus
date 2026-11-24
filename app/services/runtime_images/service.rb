module RuntimeImages
  # Records durable image state and delegates storage to the namespace's
  # provider. The record is only created or advanced after the provider
  # succeeds, so a provider failure never leaves a falsely available image.
  class Service
    def initialize(provider: nil)
      @provider_override = provider
    end

    def publish(namespace:, source_kind:, source_ref:, platform:, source_digest: nil, provenance: {}, payload: nil)
      result = provider_for(namespace).publish(
        PublishRequest.new(namespace: namespace, source_kind: source_kind, source_ref: source_ref,
                           source_digest: source_digest, platform: platform, provenance: provenance, payload: payload)
      )
      image = RuntimeImage.find_or_initialize_by(runtime_image_namespace: namespace, digest: result.digest, platform: result.platform)
      if image.new_record?
        image.assign_attributes(source_kind: source_kind, source_ref: source_ref, source_digest: source_digest,
                                provenance: provenance, locator: result.locator)
        image.save!
      elsif image.source_kind != source_kind.to_s || image.source_ref != source_ref.to_s
        raise Error, "digest #{result.digest} is already published with a different source identity"
      end
      raise Error, "runtime image #{image.digest} was #{image.availability} and cannot be republished" if image.revoked? || image.deleted?
      image.mark_available!(locator: result.locator) if image.pending?
      image
    end

    def resolve(namespace:, reference:, platform:)
      resolution = provider_for(namespace).resolve(ResolveRequest.new(namespace: namespace, reference: reference, platform: platform))
      find_image!(namespace, resolution.digest, resolution.platform)
    end

    def inspect_image(image)
      provider_for(image.runtime_image_namespace).inspect_image(
        InspectRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform)
      )
    end

    def pull(image)
      raise NotPullable, "runtime image #{image.digest} is #{image.availability}" unless image.pullable?
      provider_for(image.runtime_image_namespace).pull(
        PullRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform, locator: image.locator)
      )
    end

    # Revocation is recorded before the provider is told, so a provider outage
    # can never leave a revoked image pullable.
    def revoke(image, reason:)
      image.mark_revoked!(reason: reason)
      provider_for(image.runtime_image_namespace).revoke(
        RevokeRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform, reason: reason)
      )
      image
    end

    def retain(image, reason: nil, until_time: nil)
      image.retain!(reason: reason, until_time: until_time)
      provider_for(image.runtime_image_namespace).retain(
        RetainRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform, retain_until: until_time)
      )
      image
    end

    def delete(image)
      raise Error, "runtime image #{image.digest} is still retained" if image.retained?
      provider_for(image.runtime_image_namespace).delete(
        DeleteRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform)
      )
      image.mark_deleted!
      image
    end

    private

    def provider_for(namespace)
      @provider_override || Providers.fetch(namespace.provider_key)
    end

    def find_image!(namespace, digest, platform)
      RuntimeImage.find_by(runtime_image_namespace: namespace, digest: digest, platform: platform) ||
        raise(NotFound, "runtime image #{digest} is not recorded in namespace #{namespace.name}")
    end
  end
end
