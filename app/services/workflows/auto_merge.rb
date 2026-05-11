module Workflows
  # Approved PR is green and ready to land.
  #
  #   apply_suggestions -> auto_merge
  #
  # The first step is intentionally non-agentic; once the GitHub-native
  # suggestion applier lands it can do that mechanical edit here. The final
  # step re-fetches PR state immediately before calling GitHub's merge API.
  class AutoMerge < Base
    steps :apply_suggestions, :auto_merge

    def self.trigger_kind = "auto_merge"
  end
end
