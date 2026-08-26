module ExternalPrIngestions
  # Story 10: a PR Syrus's own `Workflows::Promotion` opened. It is already
  # tracked as a promotion workflow record — the promotion's own anchor Job
  # and `JobPrLink` (role: `promotion`) — not ordinary feature work, so
  # ingestion creates no second Job for it. In practice `PollExternalOpenPrsJob`
  # already skips same-repo `syrus/`-prefixed branches before classification
  # ever runs, so this mostly guards a future cross-repo promotion shape (or
  # a promotion PR observed from an unusual polling path) rather than
  # today's common case.
  class SyrusPromotion < Base
    def ingest!(repository:, pr:, fork_pr:)
      Rails.logger.info(
        "[ExternalPrIngestions::SyrusPromotion] #{repository.slug}##{pr.number} recognized as a promotion PR; " \
        "tracked by its own promotion workflow, not ingested as feature work"
      )
      nil
    end
  end
end
