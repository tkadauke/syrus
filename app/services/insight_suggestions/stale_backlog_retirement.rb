module InsightSuggestions
  # Cleanup path for the legacy stale-insight backlog that predates
  # retire_insight: pending/dismissed `revise_existing_insight` rows (the
  # retired legacy proposal type) and pending/dismissed `informational` rows
  # whose only purpose is announcing that another insight is stale (title
  # starting with "Superseded by #"). Retires them through the normal audited
  # InsightSuggestion#retire! path instead of a manual DB fixup.
  class StaleBacklogRetirement
    SUPERSEDED_TITLE_PATTERN = /\ASuperseded by #/i
    REASON = "Automated backlog cleanup: legacy stale-insight pattern retired without further operator review."

    Result = Struct.new(:checked, :retired, :skipped, :errors, keyword_init: true)

    def initialize(scope: self.class.default_scope, logger: Rails.logger)
      @scope = scope
      @logger = logger
    end

    def call(dry_run: false)
      result = Result.new(checked: 0, retired: 0, skipped: 0, errors: 0)

      scope.find_each do |insight|
        result.checked += 1

        if dry_run
          result.retired += 1
          logger.info("[StaleBacklogRetirement] would retire ##{insight.id} #{insight.title.truncate(80)}")
          next
        end

        if insight.retire!(reason: REASON, actor: nil)
          result.retired += 1
          logger.info("[StaleBacklogRetirement] retired ##{insight.id} #{insight.title.truncate(80)}")
        else
          result.skipped += 1
          logger.info("[StaleBacklogRetirement] skipped ##{insight.id}: state changed concurrently")
        end
      rescue StandardError => e
        result.errors += 1
        logger.warn("[StaleBacklogRetirement] failed ##{insight.id}: #{e.class}: #{e.message}")
      end

      result
    end

    def self.default_scope
      InsightSuggestion
        .where(state: %w[pending dismissed])
        .where(
          "proposal_type = ? OR (proposal_type = ? AND title LIKE ?)",
          "revise_existing_insight", "informational", "Superseded by #%"
        )
    end

    private

    attr_reader :scope, :logger
  end
end
