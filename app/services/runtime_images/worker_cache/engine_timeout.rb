module RuntimeImages
  class WorkerCache
    # A pull exceeded its time budget.
    class EngineTimeout < EngineError; end
  end
end
