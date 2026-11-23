require "json"

module Formal
  # Proofs as production alarms (formal/INTEGRATION.md, layer 4). A reconciler
  # issue kind whose state the Lean models prove unreachable keeps its repair,
  # but its entry in formal/coverage/coverage.json says `"expected": "never"`.
  # This compares those expectations with the reconciler's recorded activity:
  # a sighting means an assumption the proof made is wrong, or the model has
  # drifted from the code. It also measures a fix after deploy, since a state a
  # fix made unreachable should stop appearing.
  #
  # Read-only. `bin/rails formal:alarms` prints the result.
  class ProvedUnreachableAlarm
    COVERAGE_PATH = Rails.root.join("formal/coverage/coverage.json")
    SAMPLE_SIZE = 5

    Sighting = Data.define(:item_id, :issue_kind, :count, :last_seen_at, :sample_event_ids)
    Result = Data.define(:since, :watched_kinds, :sightings) do
      def quiet? = sightings.empty?
    end

    def self.call(since: 24.hours.ago, coverage_path: COVERAGE_PATH)
      new(since:, coverage_path:).call
    end

    def initialize(since:, coverage_path:)
      @since = since
      @coverage_path = Pathname.new(coverage_path)
    end

    def call
      item_by_kind = watched_items.each_with_object({}) do |item, map|
        Array(item["issue_kinds"]).each { |kind| map[kind] ||= item.fetch("id") }
      end
      events = WorkEngineReconcilerActivityEvent.where(issue_kind: item_by_kind.keys).where("occurred_at >= ?", @since)
      sightings = events.group(:issue_kind).pluck(:issue_kind, Arel.sql("COUNT(*)"), Arel.sql("MAX(occurred_at)")).map do |kind, count, last_seen|
        Sighting.new(item_id: item_by_kind.fetch(kind), issue_kind: kind, count: count.to_i,
          last_seen_at: last_seen.is_a?(String) ? Time.zone.parse(last_seen) : last_seen,
          sample_event_ids: events.where(issue_kind: kind).order(occurred_at: :desc, id: :desc).limit(SAMPLE_SIZE).pluck(:id))
      end
      Result.new(since: @since, watched_kinds: item_by_kind.keys.sort, sightings: sightings.sort_by(&:issue_kind))
    end

    private

    def watched_items
      JSON.parse(@coverage_path.read).fetch("items").select { |item| item["expected"] == "never" }
    end
  end
end
