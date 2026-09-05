module VideoWalkthroughs::Prompts
  # The SHORT orientation the chat agent gets when a walkthrough video the
  # operator shared has finished analyzing. It does NOT dump the analysis into
  # the thread (that used to read as if the user typed a wall of text). Instead
  # it points the agent at its walkthrough tools and lets it work autonomously —
  # calling get_walkthrough_analysis, reading frames, then proposing an Epic —
  # so the handoff is first-class tool activity, exactly like any other Syrus
  # chat turn. The rich analysis text + screenshots come back through
  # get_walkthrough_analysis (rendered by VideoWalkthroughs::Prompts::Report).
  class Context
    def initialize(walkthrough:, user_note: nil)
      @walkthrough = walkthrough
      @user_note = user_note.to_s.strip.presence
    end

    def to_s
      parts = []
      parts << header
      parts << "The operator's note with the video: #{@user_note}" if @user_note
      parts << tools_section
      parts << closing_instruction
      parts.join("\n\n")
    end

    private

    def header
      duration = @walkthrough.duration_seconds
      length = duration ? " (#{duration / 60}m#{format('%02d', duration % 60)}s)" : ""
      <<~TEXT.strip
        The operator shared a walkthrough video#{length} of them testing the app,
        narrating as they went, and it has finished analyzing (walkthrough
        ##{@walkthrough.id}). Review it with your walkthrough tools before you
        scope anything — the analysis is not in this message; you pull it.
      TEXT
    end

    def tools_section
      <<~TEXT.strip
        Work through it like any other task, using tools:
        - Call `get_walkthrough_analysis(walkthrough_id: #{@walkthrough.id})` first.
          It returns the timestamped narration transcript, the topical sections,
          and the grounded issues — plus crisp screenshots of the flagged moments
          as images you can read directly. Read exact on-screen text (error codes,
          IDs, values) off those screenshots; never guess text you can't read.
        - For any other moment whose exact text or click sequence matters, call
          `read_walkthrough_frame(walkthrough_id: #{@walkthrough.id}, timestamp: mm:ss)`
          to grab a still, or `analyze_walkthrough_segment(walkthrough_id: #{@walkthrough.id}, ...)`
          to re-examine a time range at full resolution.
      TEXT
    end

    def closing_instruction
      <<~TEXT.strip
        Then turn it into actionable work: if the analysis (or anything you read)
        is genuinely ambiguous, ask the operator — briefly, all at once. Otherwise
        propose an Epic that groups the issues into well-scoped Jobs, using your
        normal proposal flow. Skip anything too vague to act on and say so. If the
        walkthrough surfaced no real problems, say that plainly instead of
        inventing work.
      TEXT
    end
  end
end
