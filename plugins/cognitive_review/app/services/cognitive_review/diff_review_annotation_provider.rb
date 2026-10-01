module CognitiveReview
  class DiffReviewAnnotationProvider
    include Syrus::Plugin::DiffReviewAnnotationProvider

    def self.review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
      notes = notes_for(job: job, version: version, base_sha: base_sha, head_sha: head_sha)
      return {} if notes.empty?

      open_notes = notes.select(&:open?)
      return { ranges: {}, panels: [], counts: [ open_count(open_notes) ] } if open_notes.empty?

      {
        ranges: ranges_for(open_notes),
        panels: panels_for(open_notes),
        counts: [ open_count(open_notes) ]
      }
    end

    def self.open_count(notes)
      {
        id: "cognitive_review.open",
        label: "Cognitive review",
        value: notes.size,
        tone: "warning"
      }
    end

    def self.notes_for(job:, version:, base_sha:, head_sha:)
      scope = CognitiveReview::Note.where(job: job)
      if version
        scope = scope.where(diff_review_version: version)
      else
        scope = scope.select do |note|
          metadata = note.source_metadata.to_h
          metadata["base_sha"].to_s == base_sha.to_s && metadata["head_sha"].to_s == head_sha.to_s
        end
      end
      return scope if scope.is_a?(Array)

      scope.includes(:discussion_entries).ordered.to_a
    end

    def self.ranges_for(notes)
      notes.each_with_object({}) do |note, ranges|
        path = note.path.to_s
        next if path.blank?

        ranges[path] ||= []
        ranges[path] << {
          id: "cognitive_review_note:#{note.id}",
          side: note.side,
          start_line: note.start_line,
          end_line: note.end_line,
          title: note.title,
          body: note.explanation,
          tone: "warning",
          category: note.reason_codes.first,
          confidence: note.confidence&.to_f,
          state: note.state,
          priority: note.priority
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
