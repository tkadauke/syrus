module Python
  # :review_criteria_provider seeding a default adversarial-review checklist
  # item for Python code: missing type hints on new public functions erode
  # the value of static analysis (mypy/pyright) for every downstream caller.
  class ReviewCriteriaProvider
    def self.criteria(repo_path)
      return [] unless Python::PrepareDetector.detect?(repo_path)

      [ "Flag missing type hints on new public functions" ]
    end
  end
end
