module RuntimeImages
  class WorkerCache
    # Pull concurrency is exhausted and the wait budget ran out.
    class Busy < RuntimeImages::Error; end
  end
end
