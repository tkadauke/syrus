module CognitiveReview
  class DiffReviewAnnotationProvider
    include Syrus::Plugin::DiffReviewAnnotationProvider

    def self.review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
      notes = notes_for(job: job, version: version, base_sha: base_sha, head_sha: head_sha)
      return {} if notes.empty? && version.blank?

      rollup = CognitiveReview::DebtRollup.for(job: job, diff_review_version: version, notes: notes)
      open_notes = notes.select(&:open?)
      {
        ranges: open_notes.empty? ? {} : ranges_for(open_notes),
        panels: panels_for(open_notes, rollup),
        counts: counts_for(rollup)
      }
    end

    def self.counts_for(rollup)
      [
        count_payload("cognitive_review.total", "Flagged ranges", rollup.total_flagged_ranges, "default"),
        count_payload("cognitive_review.open", "Open debt", rollup.open_unhandled_count, rollup.open_unhandled_count.positive? ? "warning" : "success"),
        count_payload("cognitive_review.handled", "Handled", rollup.handled_count, "success"),
        count_payload("cognitive_review.dismissed", "Dismissed", rollup.dismissed_count, "default")
      ]
    end

    def self.count_payload(id, label, value, tone)
      { id: id, label: label, value: value, tone: tone }
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

    def self.panels_for(notes, rollup)
      [
        {
          id: "cognitive_review.summary",
          component: "cognitive_review/note_panel",
          title: "Cognitive review debt",
          body: panel_body(rollup),
          tone: rollup.open_unhandled_count.positive? ? "warning" : "success",
          props: {
            notes: notes.map { |note| note_props(note) },
            rollup: rollup.as_json,
            total: notes.size
          }
        }
      ]
    end

    def self.panel_body(rollup)
      return "No PR-level cognitive review debt was flagged for this diff version." if rollup.zero_note_state?

      "#{rollup.open_unhandled_count} open, #{rollup.handled_count} handled, #{rollup.dismissed_count} dismissed across #{rollup.total_flagged_ranges} flagged range#{'s' unless rollup.total_flagged_ranges == 1}."
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
