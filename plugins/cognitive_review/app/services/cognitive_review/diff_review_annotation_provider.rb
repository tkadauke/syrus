module CognitiveReview
  class DiffReviewAnnotationProvider
    include Syrus::Plugin::DiffReviewAnnotationProvider

    def self.review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
      notes = Artifact.latest_notes_for(job)
      return {} if notes.empty?

      {
        ranges: ranges_for(notes),
        panels: panels_for(notes),
        counts: [
          {
            id: "cognitive_review.open",
            label: "Cognitive review",
            value: notes.size,
            tone: "warning"
          }
        ]
      }
    end

    def self.ranges_for(notes)
      notes.each_with_object({}) do |note, ranges|
        path = note["path"].to_s
        next if path.blank?

        ranges[path] ||= []
        ranges[path] << {
          id: note["id"],
          side: note["side"],
          start_line: note["start_line"],
          end_line: note["end_line"],
          title: note["title"],
          body: note["body"],
          tone: note["tone"] || "warning",
          category: note["category"],
          confidence: note["confidence"]
        }.compact
      end
    end

    def self.panels_for(notes)
      [
        {
          id: "cognitive_review.summary",
          title: "Cognitive review",
          body: "#{notes.size} note#{'s' unless notes.one?} flagged for operator attention.",
          tone: "warning"
        }
      ]
    end
  end
end
