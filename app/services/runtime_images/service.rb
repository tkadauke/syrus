module RuntimeImages
  # Records durable image state and delegates storage to the namespace's
  # provider. The record is only created or advanced after the provider
  # succeeds, so a provider failure never leaves a falsely available image.
  class Service
    def initialize(provider: nil)
      @provider_override = provider
    end

    def publish(namespace:, source_kind:, source_ref:, platform:, source_digest: nil, provenance: {}, payload: nil)
      audited("publish", namespace: namespace) do
        publish_image(namespace: namespace, source_kind: source_kind, source_ref: source_ref, platform: platform,
                      source_digest: source_digest, provenance: provenance, payload: payload)
      end
    end

    def publish_image(namespace:, source_kind:, source_ref:, platform:, source_digest:, provenance:, payload:)
      result = provider_for(namespace).publish(
        PublishRequest.new(namespace: namespace, source_kind: source_kind, source_ref: source_ref,
                           source_digest: source_digest, platform: platform, provenance: provenance, payload: payload)
      )
      image = RuntimeImage.find_or_initialize_by(runtime_image_namespace: namespace, digest: result.digest, platform: result.platform)
      if image.new_record?
        image.assign_attributes(source_kind: source_kind, source_ref: source_ref, source_digest: source_digest,
                                provenance: provenance, locator: result.locator)
        image.save!
      end
      if image.revoked? || image.deleted?
        # Providers must treat publish as idempotent and never reactivate a
        # digest, but do not rely on it: re-assert the terminal state so the
        # backing store cannot disagree with the durable record.
        enforce_terminal_state(image)
        raise Error, "runtime image #{image.digest} was #{image.availability} and cannot be republished"
      end
      if !image.previously_new_record? && (image.source_kind != source_kind.to_s || image.source_ref != source_ref.to_s)
        raise Error, "digest #{result.digest} is already published with a different source identity"
      end
      image.mark_available!(locator: result.locator) if image.pending?
      image
    end
    private :publish_image

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
    def revoke(image, reason:, actor: "system")
      audited("revoke", image: image, actor: actor, details: { reason: reason }) do
        image.mark_revoked!(reason: reason)
        provider_for(image.runtime_image_namespace).revoke(
          RevokeRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform, reason: reason)
        )
        image
      end
    end

    def retain(image, reason: nil, until_time: nil, actor: "system")
      audited("retain", image: image, actor: actor, details: { reason: reason, until: until_time&.iso8601 }) do
        image.retain!(reason: reason, until_time: until_time)
        provider_for(image.runtime_image_namespace).retain(
          RetainRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform, retain_until: until_time)
        )
        image
      end
    end

    # Deletion order: the durable record is only marked deleted after the
    # provider confirmed removal, so a failed provider call leaves a record
    # that still describes what the registry holds.
    def delete(image, actor: "system")
      audited("delete", image: image, actor: actor) do
        raise Error, "runtime image #{image.digest} is still retained" if image.retained?
        provider_for(image.runtime_image_namespace).delete(
          DeleteRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform)
        )
        image.mark_deleted!
        image
      end
    end

    # Digests the provider holds for a namespace, for orphan reconciliation.
    # Raises Unsupported when the provider cannot enumerate.
    def list_digests(namespace)
      provider_for(namespace).list(ListRequest.new(namespace: namespace))
    end

    # Re-tells the provider to remove a revoked or deleted image.
    def reassert_removal(image) = enforce_terminal_state(image)

    # Removes a stored digest that has no durable record.
    def delete_unrecorded(namespace, digest, platform: "linux/amd64")
      provider_for(namespace).delete(DeleteRequest.new(namespace: namespace, digest: digest, platform: platform))
    end

    private

    # Runs an operation, auditing the outcome. Authentication failures are
    # audited as their own event so credential problems are visible apart
    # from ordinary provider errors. The original error always propagates.
    def audited(kind, image: nil, namespace: nil, actor: "system", details: {})
      result = yield
      Audit.record("#{kind}", outcome: :ok, image: result.is_a?(RuntimeImage) ? result : image, namespace: namespace,
                   actor: actor, details: details)
      result
    rescue AuthenticationError => e
      Audit.record("auth", outcome: :failed, image: image, namespace: namespace, actor: actor,
                   details: details.merge(operation: kind, error: e.message))
      Audit.record(kind, outcome: :failed, image: image, namespace: namespace, actor: actor, details: details.merge(error: e.message))
      raise
    rescue Error, RuntimeImage::InvalidTransition => e
      Audit.record(kind, outcome: :failed, image: image, namespace: namespace, actor: actor,
                   details: details.merge(error_class: e.class.name, error: e.message))
      raise
    end

    def enforce_terminal_state(image)
      provider = provider_for(image.runtime_image_namespace)
      if image.revoked?
        provider.revoke(RevokeRequest.new(namespace: image.runtime_image_namespace, digest: image.digest,
                                          platform: image.platform, reason: image.revoked_reason))
      else
        provider.delete(DeleteRequest.new(namespace: image.runtime_image_namespace, digest: image.digest, platform: image.platform))
      end
    end

    def provider_for(namespace)
      @provider_override || Providers.fetch(namespace.provider_key)
    end

    def find_image!(namespace, digest, platform)
      RuntimeImage.find_by(runtime_image_namespace: namespace, digest: digest, platform: platform) ||
        raise(NotFound, "runtime image #{digest} is not recorded in namespace #{namespace.name}")
    end
  end
end
