module ExternalPrIngestions
  # Story 9/10: an ordinary external PR with no recognizable Syrus
  # provenance (a human's hand-written branch, or a fork Syrus doesn't know
  # about). Unchanged from `PollExternalOpenPrsJob`'s pre-classification
  # behavior: create the `external_pr` Job and grade it, no prior Syrus
  # context assumed.
  class ExternalUnknown < Base
    def ingest!(repository:, pr:, fork_pr:)
      JobFactory.create!(repository: repository, pr: pr, fork_pr: fork_pr)
    end
  end
end
