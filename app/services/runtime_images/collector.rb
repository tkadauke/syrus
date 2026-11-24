module RuntimeImages
  # Garbage collection of stored runtime images, driven by the shared
  # retention policy (RetentionPolicyRegistry key :runtime_image) and optional
  # per-namespace retention_days overrides.
  #
  # An image is only a candidate when no retention hold protects it, it is
  # older than its window, and it is not the newest pullable image for its
  # namespace and platform (so the current image is never collected even when
  # a namespace has gone quiet). Deletion is ordered so a failure at any step
  # leaves a safe state:
  #
  #   1. revoke  - recorded durably first; the image can no longer be pulled
  #   2. lease   - skipped while any worker still holds the image in use
  #   3. delete  - provider removal; only then is the record marked deleted
  #
  # Failures are recorded on the image and retried on the next pass; they never
  # abort the rest of the batch.
  class Collector
    DEFAULT_BATCH = 25
    MAX_CLEANUP_ATTEMPTS = 5

    Result = Data.define(:deleted, :failed, :skipped, :backlog)

    def initialize(service: Service.new, global_window: nil, batch: DEFAULT_BATCH, now: Time.current)
      @service = service
      @global_window = global_window
      @batch = batch
      @now = now
    end

    def call
      expire_retention
      candidates = candidate_images
      deleted = failed = skipped = 0
      candidates.first(@batch).each do |image|
        case collect(image)
        when :deleted then deleted += 1
        when :failed then failed += 1
        else skipped += 1
        end
      end
      Result.new(deleted: deleted, failed: failed, skipped: skipped, backlog: candidates.size > @batch)
    end

    # Candidate images across the global window and every namespace override,
    # oldest first.
    def candidate_images
      keep = newest_pullable_ids
      scope = RuntimeImage.prunable(@now).where.not(id: keep.presence || [ 0 ]).joins(:runtime_image_namespace)
      images = []
      images.concat(scope.where(runtime_image_namespaces: { retention_days: nil })
                         .where(published_at: ...(@now - @global_window)).to_a) if @global_window
      scope.where.not(runtime_image_namespaces: { retention_days: nil }).distinct
           .pluck("runtime_image_namespaces.retention_days").each do |days|
        images.concat(scope.where(runtime_image_namespaces: { retention_days: days })
                           .where(published_at: ...(@now - days.days)).to_a)
      end
      images.sort_by { |image| [ image.published_at, image.id ] }
    end

    private

    def expire_retention
      RuntimeImage.retention_expired(@now).find_each do |image|
        image.update!(retention_state: "expired")
        Audit.record("retention.expire", outcome: :ok, image: image, details: { reason: image.retention_reason })
      end
    end

    def newest_pullable_ids
      RuntimeImage.pullable.group(:runtime_image_namespace_id, :platform).maximum(:id).values
    end

    def collect(image)
      if image.cleanup_failure_count >= MAX_CLEANUP_ATTEMPTS
        Audit.record("gc.delete", outcome: :skipped, image: image, details: { reason: "cleanup attempts exhausted" })
        return :skipped
      end
      if leased?(image)
        Audit.record("gc.delete", outcome: :skipped, image: image, details: { reason: "image is leased by a worker" })
        return :skipped
      end
      @service.revoke(image, reason: "garbage collected after retention window", actor: "gc") if image.available?
      @service.delete(image, actor: "gc")
      Audit.record("gc.delete", outcome: :ok, image: image)
      :deleted
    rescue Error, RuntimeImage::InvalidTransition, ActiveRecord::ActiveRecordError => e
      image.record_cleanup_failure!(e)
      Audit.record("gc.delete", outcome: :failed, image: image, details: { error_class: e.class.name, error: e.message })
      :failed
    end

    def leased?(image)
      RuntimeImageCacheEntry.where(runtime_image_id: image.id).any? { |entry| entry.leased?(@now) }
    end
  end
end
