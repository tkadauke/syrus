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

      def size_bytes(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #size_bytes")
      def remove(_reference) = raise(NotImplementedError, "#{self.class.name} must implement #remove")

      # { total_bytes:, free_bytes: } for the filesystem backing the cache.
      def disk_usage = raise(NotImplementedError, "#{self.class.name} must implement #disk_usage")
    end
  end
end
