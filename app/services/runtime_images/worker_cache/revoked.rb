module RuntimeImages
  class WorkerCache
    # The image was revoked or deleted before or during the pull.
    class Revoked < RuntimeImages::Error; end
  end
end
