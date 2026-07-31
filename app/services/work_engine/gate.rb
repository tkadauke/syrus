module WorkEngine
  class Gate
    FEATURE_SLUG = "unified_work_engine_reconciler"

    def self.enabled?
      Feature.enabled?(FEATURE_SLUG)
    end
  end
end
