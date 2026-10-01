module CognitiveReview
  class DiffReviewAnnotationProvider
    include Syrus::Plugin::DiffReviewAnnotationProvider
    COMMENT_SIDE_BY_NOTE_SIDE = { "old" => "left", "new" => "right" }.freeze
    COMMENT_LINE_BY_NOTE_SIDE = {
      "old" => ->(comment) { comment.old_line.to_i },
      "new" => ->(comment) { comment.new_line.to_i }
    }.freeze

    def self.review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
      notes = notes_for(job: job, version: version, base_sha: base_sha, head_sha: head_sha)
      return {} if notes.empty?

      open_notes = notes.select(&:open?)
      return { ranges: {}, panels: [], counts: [ open_count(open_notes) ] } if open_notes.empty?

      comments_by_note_id = matching_comments_by_note_id(open_notes)
      {
        ranges: ranges_for(open_notes, comments_by_note_id: comments_by_note_id),
        panels: panels_for(open_notes, comments_by_note_id: comments_by_note_id),
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

    def self.ranges_for(notes, comments_by_note_id: {})
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
          props: note_props(note, matching_comments: comments_by_note_id[note.id] || [])
        }.compact
      end
    end

    def self.panels_for(notes, comments_by_note_id: {})
      [
        {
          id: "cognitive_review.summary",
          component: "cognitive_review/note_panel",
          title: "Review Notes",
          body: "#{notes.size} note#{'s' unless notes.one?} flagged for operator attention.",
          tone: "warning",
          props: {
            notes: notes.map { |note| note_props(note, matching_comments: comments_by_note_id[note.id] || []) },
            total: notes.size
          }
        }
      ]
    end

    def self.note_props(note, matching_comments: [])
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
        handled_by_comment: matching_comments.any?,
        handled_by_comment_count: matching_comments.size,
        handled_by_comment_ids: matching_comments.map(&:id),
        discussion_entries: discussion_entries_for(note).map do |entry|
          {
            id: entry.id,
            body: entry.body,
            created_at: entry.created_at&.iso8601
          }
        end
      }.compact
    end

    def self.matching_comments_by_note_id(notes)
      return {} if notes.empty?

      comments = DiffReviewComment
        .where(job_id: notes.map(&:job_id).uniq, diff_review_version_id: notes.map(&:diff_review_version_id).uniq)
        .where(anchor_kind: "line")
        .where.not(state: "superseded")
        .where(path: notes.map(&:path).uniq)
        .to_a

      notes.each_with_object({}) do |note, matches|
        matches[note.id] = comments.select { |comment| comment_matches_note_range?(comment, note) }
      end
    end

    def self.comment_matches_note_range?(comment, note)
      comment.path == note.path &&
        comment.side == comment_side_for_note(note) &&
        comment_line_number(comment, note).between?(note.start_line, note.end_line)
    end

    def self.comment_side_for_note(note)
      COMMENT_SIDE_BY_NOTE_SIDE.fetch(note.side)
    end

    def self.comment_line_number(comment, note)
      COMMENT_LINE_BY_NOTE_SIDE.fetch(note.side).call(comment)
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
