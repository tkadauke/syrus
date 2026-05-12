module Steps
  # Pre-applies GitHub native suggested-change blocks before the
  # agent sees PR feedback. Clean suggestion-only feedback can then
  # skip the agentic respond/summarize steps and go straight to push.
  class ApplySuggestions < Base
    SUGGESTION_BLOCK = /
      ```suggestion[^\n]*\r?\n
      (?<content>.*?)
      \r?\n```
    /mx.freeze

    def call
      workspace.setup

      comments = Array(workflow.artifact("pr_comments"))
      suggestions = comments.flat_map { |comment| suggestions_for(comment) }
      return log("apply_suggestions: no GitHub suggested-change blocks found") if suggestions.empty?

      conflicts = validate_suggestions(suggestions)
      if conflicts.any?
        record_conflicts!(conflicts)
        log("apply_suggestions: #{conflicts.size} suggestion(s) could not be applied cleanly; leaving feedback for agent")
        return
      end

      suggestions.group_by { |suggestion| suggestion[:path] }.each_value do |path_suggestions|
        apply_path_suggestions(path_suggestions)
      end

      commit_sha = commit_suggestions!(suggestions)
      workflow.set_artifact!("applied_suggestions", applied_payload(suggestions, commit_sha))
      log("apply_suggestions: applied #{suggestions.size} suggestion(s) in #{commit_sha}")

      skip_agent_steps! if all_feedback_was_auto_applied?(comments)
    end

    private

    def suggestions_for(comment)
      return [] if comment["path"].blank?

      body = comment["body"].to_s
      body.to_enum(:scan, SUGGESTION_BLOCK).map do
        content = Regexp.last_match[:content]
        {
          comment_id: comment["id"],
          author: comment["author"].presence || "reviewer",
          path: comment["path"],
          start_line: (comment["start_line"].presence || comment["line"]).to_i,
          line: comment["line"].to_i,
          diff_hunk: comment["diff_hunk"],
          replacement: content
        }
      end
    end

    def validate_suggestions(suggestions)
      conflicts = []
      suggestions.each do |suggestion|
        file = workspace.path.join(suggestion[:path])
        conflicts << conflict_for(suggestion, "file is missing") unless file.file?
        conflicts << conflict_for(suggestion, "comment line is missing") if suggestion[:start_line] <= 0 || suggestion[:line] <= 0
        conflicts << conflict_for(suggestion, "comment range is inverted") if suggestion[:start_line] > suggestion[:line]
      end

      suggestions.group_by { |suggestion| suggestion[:path] }.each_value do |path_suggestions|
        path_suggestions.combination(2) do |a, b|
          next if a[:line] < b[:start_line] || b[:line] < a[:start_line]
          conflicts << conflict_for(b, "overlaps another suggestion on #{b[:path]}:#{b[:start_line]}-#{b[:line]}")
        end
      end

      suggestions.group_by { |suggestion| suggestion[:path] }.each do |path, path_suggestions|
        file = workspace.path.join(path)
        next unless file.file?
        lines = File.readlines(file, chomp: true)
        line_count = lines.size
        path_suggestions.each do |suggestion|
          if suggestion[:line] > line_count
            conflicts << conflict_for(suggestion, "comment line #{suggestion[:line]} is past end of file (#{line_count} lines)")
            next
          end

          expected = expected_lines_from_diff_hunk(suggestion)
          next unless expected

          actual = lines[(suggestion[:start_line] - 1)..(suggestion[:line] - 1)]
          if actual != expected
            conflicts << conflict_for(suggestion, "comment range no longer matches the reviewed diff")
          end
        end
      end

      conflicts
    end

    def expected_lines_from_diff_hunk(suggestion)
      diff_hunk = suggestion[:diff_hunk].to_s
      return nil if diff_hunk.blank?

      current_line = nil
      expected = []

      diff_hunk.each_line do |line|
        if (match = line.match(/\A@@ -\d+(?:,\d+)? \+(?<start>\d+)(?:,\d+)? @@/))
          current_line = match[:start].to_i
          next
        end
        next unless current_line
        next if line.start_with?("\\")

        marker = line[0]
        body = line[1..]&.delete_suffix("\n")
        case marker
        when " ", "+"
          if current_line.between?(suggestion[:start_line], suggestion[:line])
            expected << body
          end
          current_line += 1
        when "-"
          next
        end
      end

      return nil if expected.empty?

      expected
    end

    def conflict_for(suggestion, reason)
      {
        "comment_id" => suggestion[:comment_id],
        "author" => suggestion[:author],
        "path" => suggestion[:path],
        "start_line" => suggestion[:start_line],
        "line" => suggestion[:line],
        "reason" => reason
      }
    end

    def record_conflicts!(conflicts)
      workflow.set_artifact!("suggestion_conflicts", conflicts)
    end

    def apply_path_suggestions(suggestions)
      file = workspace.path.join(suggestions.first[:path])
      lines = File.readlines(file, chomp: true)

      suggestions.sort_by { |suggestion| -suggestion[:start_line] }.each do |suggestion|
        replacement = suggestion[:replacement].split(/\r?\n/, -1)
        replacement.pop if replacement.last == ""
        lines[(suggestion[:start_line] - 1)..(suggestion[:line] - 1)] = replacement
      end

      File.write(file, lines.join("\n") + "\n")
    end

    def commit_suggestions!(suggestions)
      chdir = workspace.path.to_s
      git = streaming_git
      status = git.run("status", "--porcelain", chdir: chdir)
      raise StepFailed, "suggestions produced no changes" if status.strip.empty?

      git.run("add", "-A", chdir: chdir)
      git.run(
        "-c", "user.name=Syrus", "-c", "user.email=syrus@noreply.invalid",
        "commit", "-m", commit_message_for(suggestions),
        chdir: chdir
      )
      assert_branch_history_intact!
      head_sha
    end

    def commit_message_for(suggestions)
      authors = suggestions.map { |suggestion| suggestion[:author] }.uniq
      if authors.one?
        count = suggestions.size == 1 ? "change" : "changes"
        "Apply suggested #{count} from #{authors.first}"
      else
        "Apply suggested changes from #{authors.to_sentence}"
      end
    end

    def applied_payload(suggestions, commit_sha)
      suggestions.map do |suggestion|
        {
          "comment_id" => suggestion[:comment_id],
          "author" => suggestion[:author],
          "path" => suggestion[:path],
          "start_line" => suggestion[:start_line],
          "line" => suggestion[:line],
          "commit_sha" => commit_sha
        }
      end
    end

    def all_feedback_was_auto_applied?(comments)
      applied_ids = Array(workflow.artifact("applied_suggestions")).map { |s| s["comment_id"] }.compact
      comments.all? do |comment|
        applied_ids.include?(comment["id"]) && without_suggestion_blocks(comment["body"]).blank?
      end
    end

    def without_suggestion_blocks(body)
      body.to_s.gsub(SUGGESTION_BLOCK, "").strip
    end

    def skip_agent_steps!
      %w[ respond summarize_amend ].each do |kind|
        skipped = workflow.steps.find { |candidate| candidate.kind == kind }
        next unless skipped&.may_cancel?
        skipped.cancel!
        skipped.save!
      end
      log("apply_suggestions: feedback was suggestion-only; skipping agent response")
    end
  end
end
