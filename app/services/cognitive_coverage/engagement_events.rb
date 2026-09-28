require_dependency "cognitive_coverage/snapshot"

module CognitiveCoverage
  class EngagementEvents
    def self.for(repository)
      new(repository).call
    end

    def initialize(repository)
      @repository = repository
    end

    def call
      CognitiveEngagementEvent
        .where(repository: @repository)
        .order(:occurred_at, :id)
        .flat_map { |event| engagements_for(event) }
    end

    private

    def engagements_for(event)
      anchor = Anchor.for(event)
      return [] unless anchor

      anchor.engagements
    end

    class Anchor
      def self.for(event)
        ANCHOR_TYPES[event.anchor_kind]&.new(event)
      end

      def initialize(event)
        @event = event
      end

      private

      attr_reader :event

      def source_sha
        event.side == "left" ? event.base_sha : (event.head_sha || event.commit_sha)
      end

      def engagement_for(line_number)
        Engagement.new(
          path: event.path,
          line_number: line_number,
          engaged_at: event.occurred_at,
          source: event.source_type,
          source_sha: source_sha
        )
      end
    end

    class RangeAnchor < Anchor
      def engagements
        return [] if event.path.blank? || event.start_line.blank? || event.end_line.blank?

        (event.start_line..event.end_line).map { |line_number| engagement_for(line_number) }
      end
    end

    class FileAnchor < Anchor
      def engagements
        return [] if event.path.blank?

        [ engagement_for(nil) ]
      end
    end

    ANCHOR_TYPES = {
      "range" => RangeAnchor,
      "file" => FileAnchor
    }.freeze
  end
end
