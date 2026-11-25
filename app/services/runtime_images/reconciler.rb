module RuntimeImages
  # Compares durable RuntimeImage records with what each namespace's provider
  # actually holds and repairs drift in the safe direction:
  #
  # * stale pending record, provider has it   -> mark available
  # * stale pending record, provider lacks it -> mark deleted (abandoned publish)
  # * available record the provider lost      -> mark deleted (nothing to pull)
  # * revoked/deleted record still stored     -> re-assert provider removal
  # * stored digest with no record (orphan)   -> reported; removed only when
  #                                              delete_orphans is set
  #
  # A record is never made *more* available by reconciliation except for a
  # stale pending record the provider proves exists. Orphan removal is opt-in
  # because a publish that is mid-flight (manifest pushed, record not yet
  # written) is indistinguishable from an orphan; the digest is re-checked
  # against the database immediately before deletion to narrow that window.
  class Reconciler
    PENDING_GRACE = 1.hour
    Finding = Data.define(:kind, :namespace, :digest, :action, :detail)

    attr_reader :findings

    def initialize(service: Service.new, delete_orphans: false, repair: true, now: Time.current, batch: 500)
      @service = service
      @delete_orphans = delete_orphans
      @repair = repair
      @now = now
      @batch = batch
      @findings = []
    end

    def call
      RuntimeImageNamespace.find_each do |namespace|
        reconcile_records(namespace)
        reconcile_orphans(namespace)
      rescue Error => e
        add(:namespace_unreachable, namespace, nil, :none, "#{e.class.name.demodulize}: #{e.message}")
        Audit.record("reconcile.namespace", outcome: :failed, namespace: namespace, details: { error: e.message })
      end
      @findings
    end

    private

    def reconcile_records(namespace)
      RuntimeImage.where(runtime_image_namespace: namespace).where.not(availability: "deleted").find_each(batch_size: @batch) do |image|
        inspection = @service.inspect_image(image)
        case image.availability
        when "pending" then reconcile_pending(image, inspection)
        when "available" then reconcile_available(image, inspection)
        when "revoked" then reconcile_revoked(image, inspection)
        end
      rescue AuthenticationError
        raise
      rescue Error => e
        add(:inspect_failed, namespace, image.digest, :none, e.message)
      end
    end

    def reconcile_pending(image, inspection)
      return if image.created_at > @now - PENDING_GRACE
      if inspection.present
        repair(image, :stale_pending, "mark available") { image.mark_available! }
      else
        repair(image, :stale_pending, "mark deleted") { image.mark_deleted! }
      end
    end

    def reconcile_available(image, inspection)
      return if inspection.present
      repair(image, :missing_in_registry, "mark deleted") { image.mark_deleted! }
    end

    def reconcile_revoked(image, inspection)
      return unless inspection.present
      repair(image, :revoked_still_stored, "re-assert revoke") { @service.reassert_removal(image) }
    end

    def reconcile_orphans(namespace)
      known = RuntimeImage.where(runtime_image_namespace: namespace).pluck(:digest).to_set
      @service.list_digests(namespace).reject { |digest| known.include?(digest) }.each do |digest|
        next add(:orphan_digest, namespace, digest, :none, "stored without a record") unless @delete_orphans && @repair
        remove_orphan(namespace, digest)
      end
    rescue Unsupported => e
      add(:listing_unsupported, namespace, nil, :none, e.message)
    end

    def remove_orphan(namespace, digest)
      return if RuntimeImage.exists?(runtime_image_namespace: namespace, digest: digest)
      @service.delete_unrecorded(namespace, digest)
      add(:orphan_digest, namespace, digest, :deleted, "stored without a record")
      Audit.record("reconcile.orphan_digest", outcome: :repaired, namespace: namespace, digest: digest, details: { action: "deleted" })
    rescue Error => e
      add(:orphan_digest, namespace, digest, :failed, e.message)
      Audit.record("reconcile.orphan_digest", outcome: :failed, namespace: namespace, digest: digest, details: { error: e.message })
    end

    def repair(image, kind, action)
      unless @repair
        add(kind, image.runtime_image_namespace, image.digest, :none, action)
        Audit.record("reconcile.#{kind}", outcome: :detected, image: image, details: { proposed: action })
        return
      end
      yield
      add(kind, image.runtime_image_namespace, image.digest, :repaired, action)
      Audit.record("reconcile.#{kind}", outcome: :repaired, image: image, details: { action: action })
    rescue Error, RuntimeImage::InvalidTransition => e
      add(kind, image.runtime_image_namespace, image.digest, :failed, e.message)
      Audit.record("reconcile.#{kind}", outcome: :failed, image: image, details: { action: action, error: e.message })
    end

    def add(kind, namespace, digest, action, detail)
      @findings << Finding.new(kind: kind, namespace: namespace.name, digest: digest, action: action, detail: detail)
    end
  end
end
