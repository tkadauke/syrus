module RuntimeImages
  class WorkerCache
    # Local container engine used by a worker. Implementations raise
    # EngineTimeout when a pull exceeds its budget and EngineError for any
    # other failure; they never raise for "image absent" (see #digests).
    class Engine
      def pull(_reference, timeout:, auth: nil) = raise(NotImplementedError, "#{self.class.name} must implement #pull")

      # Content digests the engine can prove for a locally stored reference,
      # or [] when the image is absent.
      def digests(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #digests")

      # Exports a locally stored image as { manifest: String, blobs: { digest => bytes } }
      # in the shape OciRegistry::Provider#publish expects, for the given
      # "os/arch" platform. Raises EngineError when the engine cannot produce
      # an OCI layout.
      def export_oci(_reference, platform:, timeout: 600) = raise(NotImplementedError, "#{self.class.name} must implement #export_oci")

      # OCI image labels (String => String) of a locally stored reference, read
      # from the engine's own copy, or {} when the image is absent.
      def labels(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #labels")

      def size_bytes(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #size_bytes")
      # Upper bound, in seconds, on #remove. WorkerCache requires its eviction
      # claim TTL to exceed this so a stale-claim takeover never overlaps a
      # removal that is still running.
      def remove_timeout = 120

      def remove(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #remove")

      # { total_bytes:, free_bytes: } for the filesystem backing the cache.
      def disk_usage = raise(NotImplementedError, "#{self.class.name} must implement #disk_usage")
    end
  end
end
