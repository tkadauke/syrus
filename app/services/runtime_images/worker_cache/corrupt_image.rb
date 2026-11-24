module RuntimeImages
  class WorkerCache
    # Pulled content does not carry the digest it was requested by.
    class CorruptImage < RuntimeImages::Error; end
  end
end
