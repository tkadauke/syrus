module Go
  # :review_criteria_provider seeding a default adversarial-review checklist
  # item for Go code: `_ = err` silently discards an error a caller should
  # have handled or propagated, and is trivial for a reviewer to grep for.
  class ReviewCriteriaProvider
    def self.criteria(repo_path)
      return [] unless Go::PrepareDetector.detect?(repo_path)

      [ "Flag swallowed errors (`_ = err`)" ]
    end
  end
end
