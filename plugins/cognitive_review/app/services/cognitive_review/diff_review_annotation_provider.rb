module CognitiveReview
  class DiffReviewAnnotationProvider
    include Syrus::Plugin::DiffReviewAnnotationProvider

    def self.review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
      notes = notes_for(job: job, version: version, base_sha: base_sha, head_sha: head_sha)
      return {} if notes.empty?

      open_notes = CognitiveReview::Note.open_for_pr_debt(notes)
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
        label: "Review Notes",
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
          component: "cognitive_review/note_marker",
          path: path,
          side: note.side,
          start_line: note.start_line,
          end_line: note.end_line,
          title: note.title,
          body: note.explanation,
          tone: "warning",
          category: note.reason_codes.first,
          confidence: note.confidence&.to_f,
          state: note.state,
          priority: note.priority,
          props: note_props(note)
        }.compact
      end
    end

    def self.panels_for(notes)
      [
        {
          id: "cognitive_review.summary",
          component: "cognitive_review/note_panel",
          title: "Review Notes",
          body: "#{notes.size} note#{'s' unless notes.one?} flagged for operator attention.",
          tone: "warning",
          props: {
            notes: notes.map { |note| note_props(note) },
            total: notes.size
          }
        }
      ]
    end

    def self.note_props(note)
      {
        note_id: note.id,
        job_id: note.job_id,
        path: note.path,
        side: note.side,
        start_line: note.start_line,
        end_line: note.end_line,
        title: note.title,
        summary: note.summary,
        explanation: note.explanation,
        reason_codes: note.reason_codes,
        confidence: note.confidence&.to_f,
        priority: note.priority,
        state: note.state,
        discussion_entries: discussion_entries_for(note).map do |entry|
          {
            id: entry.id,
            body: entry.body,
            created_at: entry.created_at&.iso8601
          }
        end
      }.compact
    end

    def self.discussion_entries_for(note)
      if note.association(:discussion_entries).loaded?
        note.discussion_entries.sort_by { |entry| [ entry.created_at || Time.zone.at(0), entry.id || 0 ] }
      else
        note.discussion_entries.ordered.to_a
      end
    end
  end
end
