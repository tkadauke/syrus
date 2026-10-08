module Android
  # :review_criteria_provider seeding Android-specific checklist items for
  # mobile build, artifact, and lifecycle hazards.
  class ReviewCriteriaProvider
    CRITERIA = [
      "Flag Android changes that assume SDK, emulator, or device availability without declaring the required " \
        "Linux worker capability",
      "Flag APK/AAB artifact handling that omits signing, variant, or build-type distinctions",
      "Flag emulator or device control paths that bypass the generic Runtime Session visual frame/input contract"
    ].freeze

    def self.criteria(repo_path)
      return [] unless Android::PrepareDetector.detect?(repo_path)

      CRITERIA
    end
  end
end
