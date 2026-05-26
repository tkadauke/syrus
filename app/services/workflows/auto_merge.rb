module Workflows
  # Approved PR is green and ready to land.
  #
  #   auto_merge
  #
  # Re-fetches PR state immediately before calling GitHub's merge API.
  class AutoMerge < Base
    steps :auto_merge

    def self.trigger_kind = "auto_merge"
    def self.agentic? = false

    def self.after_success(_workflow)
      LandingQueueProcessor.try_land!
    end
  end
end
