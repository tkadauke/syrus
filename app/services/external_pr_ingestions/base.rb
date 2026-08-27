# Ingestion behavior for one `PrProvenanceClassifier` classification, per
# docs/plans/delivery-tracks-and-promotion.md Story 10. `PollExternalOpenPrsJob`
# classifies first, then dispatches to `.for(classification).ingest!` — a
# class hierarchy instead of a `case classification` chain, so a new
# classification only needs a new subclass, not a new branch scattered
# through the poller (see CLAUDE.md's enum-driven-behavior convention).
#
# `#ingest!` returns the `Job` it created or attached to, or `nil` when the
# classification deliberately creates no review Job
# (`SyrusPromotion`/`ManualHotfix` — see their own comments).
module ExternalPrIngestions
  class Base
    def self.for(classification)
      {
        "external_unknown" => ExternalPrIngestions::ExternalUnknown,
        "syrus_job_export" => ExternalPrIngestions::SyrusJobExport,
        "syrus_branch_export" => ExternalPrIngestions::SyrusBranchExport,
        "syrus_promotion" => ExternalPrIngestions::SyrusPromotion,
        "manual_hotfix" => ExternalPrIngestions::ManualHotfix
      }.fetch(classification.to_s, ExternalPrIngestions::ExternalUnknown).new
    end

    def ingest!(repository:, pr:, fork_pr:)
      raise NotImplementedError
    end
  end
end
