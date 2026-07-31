module Prompts
  # The structured analysis the chat agent gets back when it CALLS
  # `get_walkthrough_analysis` (Mcp::Tools::GetWalkthroughAnalysisTool). This
  # is the first-class-tool-event half of the handoff: instead of a giant
  # spoofed user message dumping the analysis into the thread, the agent asks
  # for the analysis and this renders as a tool_result — narration transcript,
  # topical sections, and grounded issues. The tool also returns crisp
  # screenshots of the flagged moments as image blocks alongside this text, so
  # the OCR handoff stays intact.
  #
  # `attached_issue_keys` are the issues whose screenshot ACTUALLY rode along in
  # the same tool response (keyed on parsed-seconds + title), so per-issue OCR
  # steering ("read the attached screenshot" vs "fetch it yourself") is truthful.
  class VideoWalkthroughReport
    SEVERITY_ORDER = %w[high medium low].freeze

    # Stable identity matching a rendered issue to an attached screenshot — the
    # tool builds the same key from each frame it extracted. Change both together.
    def self.attachment_key(seconds:, title:)
      [ seconds, title.to_s ]
    end

    def initialize(walkthrough:, attached_issue_keys: [])
      @walkthrough = walkthrough
      @attached_issue_keys = Array(attached_issue_keys)
    end

    def to_s
      parts = []
      parts << "## Session summary\n#{@walkthrough.analysis_summary}" if @walkthrough.analysis_summary.present?
      parts << sections_section if sections.any?
      parts << issues_section
      parts << ocr_guidance if ocr_relevant?
      parts << transcript_section if transcript.any?
      parts << open_questions_section if @walkthrough.analysis_open_questions.any?
      parts.compact.join("\n\n")
    end

    private

    def sections
      @sections ||= @walkthrough.analysis_sections
    end

    def sections_section
      lines = sections.map do |section|
        range = [ section["start"].presence, section["end"].presence ].compact.join("–")
        range = range.present? ? " (#{range})" : ""
        summary = section["summary"].presence
        "- **#{section['title']}**#{range}#{summary ? " — #{summary}" : ''}"
      end
      "## Sections\n#{lines.join("\n")}"
    end

    def issues_section
      issues = @walkthrough.analysis_issues
      return "## Issues found\n(none — the walkthrough surfaced no problems)" if issues.empty?

      sorted = issues.sort_by { |issue| SEVERITY_ORDER.index(issue["severity"].to_s) || SEVERITY_ORDER.length }
      "## Issues found (#{issues.size})\n#{sorted.map { |issue| render_issue(issue) }.join("\n")}"
    end

    def render_issue(issue)
      timestamp = issue["timestamp"].presence
      surface = issue["surface"].presence
      flags = []
      flags << "user-flagged" if issue["user_flagged"]
      flags << "needs a closer look" if issue["needs_closer_look"]
      meta = [ issue["severity"], surface, timestamp && "at #{timestamp}", *flags ].compact.join(", ")

      lines = [ "- **#{issue['title']}** (#{meta})" ]
      lines << "  #{issue['description']}" if issue["description"].present?
      lines << "  The user said: \"#{issue['transcript_evidence']}\"" if issue["transcript_evidence"].present?
      lines << "  On screen: #{issue['visual_evidence']}" if issue["visual_evidence"].present?
      lines << unreadable_line(issue) if issue["unreadable_text"].present?
      lines.join("\n")
    end

    # Per-issue OCR steering. Promise a screenshot ONLY when this issue's frame
    # actually rode along in the tool response; otherwise point at the on-demand
    # fetch so we never claim a still that isn't there.
    def unreadable_line(issue)
      want = issue["unreadable_text"].to_s.strip
      if attached?(issue)
        "  Too small to read from the video — read the exact text off the screenshot attached below: #{want}"
      else
        "  Too small to read from the video — call " \
          "read_walkthrough_frame(walkthrough_id: #{@walkthrough.id}, timestamp: #{issue['timestamp'].presence || 'mm:ss'}) " \
          "to grab a crisp still, then read: #{want}"
      end
    end

    def attached?(issue)
      key = self.class.attachment_key(
        seconds: Gemini::FrameExtractor.parse_timestamp(issue["timestamp"]),
        title: issue["title"]
      )
      @attached_issue_keys.include?(key)
    end

    def unreadable_issues
      @unreadable_issues ||= @walkthrough.analysis_issues.select do |issue|
        issue["unreadable_text"].to_s.strip.present?
      end
    end

    def ocr_relevant?
      @attached_issue_keys.any? || unreadable_issues.any?
    end

    # The never-invent guardrail, once, covering both the attached screenshots
    # and the on-demand fetch path.
    def ocr_guidance
      <<~TEXT.strip
        ## Reading small on-screen text
        The video model can't reliably read small on-screen text (error codes,
        IDs, URLs, config values, exact numbers, stack traces), so it deliberately
        did NOT transcribe those — it flagged them instead. The screenshots
        attached to this result capture those flagged moments, and you read still
        images far better than the video model reads video. READ the exact
        characters directly off the relevant screenshot and use the EXACT value.
        NEVER invent, guess, autocomplete, or paraphrase a value you cannot read;
        if a screenshot isn't legible, grab a fresh one with
        read_walkthrough_frame(walkthrough_id: #{@walkthrough.id}, timestamp:
        <mm:ss>), and if you still can't read it, say so.
      TEXT
    end

    def transcript
      @transcript ||= @walkthrough.analysis_transcript
    end

    def transcript_section
      lines = transcript.filter_map do |line|
        text = line["text"].presence
        next unless text

        stamp = line["timestamp"].presence
        stamp ? "[#{stamp}] #{text}" : text
      end
      return nil if lines.empty?

      "## Narration transcript\n#{lines.join("\n")}"
    end

    def open_questions_section
      questions = @walkthrough.analysis_open_questions
      <<~TEXT.strip
        ## Open questions from the analysis
        The analysis flagged these ambiguities:
        #{questions.map { |q| "- #{q}" }.join("\n")}
      TEXT
    end
  end
end
