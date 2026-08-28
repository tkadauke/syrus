module Timeline
  # Shared blocked-reason payload shaping for the worker-activity-timeline
  # plugin's macro and micro (per-workflow waterfall) queries. Both wrap
  # WorkUnits::StartBlock.explain(workflow) -- the single blocked-reason
  # source Admin::StuckJobExplainer also uses -- and iso8601-encode its
  # Time fields for JSON, so neither query service reimplements the shaping.
  class BlockedExplanation
    def self.for(workflow)
      blocked = WorkUnits::StartBlock.explain(workflow)
      blocked.merge(
        blocked_since: blocked[:blocked_since]&.iso8601,
        next_check_at: blocked[:next_check_at]&.iso8601
      )
    end
  end
end
