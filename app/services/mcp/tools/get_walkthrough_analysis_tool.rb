require "mcp"
require "tempfile"

module Mcp::Tools
  # The entry point of the walkthrough handoff: return the structured analysis of
  # a walkthrough video — narration transcript, topical sections, grounded issues
  # — PLUS crisp screenshots of the flagged moments as native image blocks the
  # agent reads directly. This is what makes the handoff first-class tool
  # activity: the chat agent CALLS this (rendering a tool_use / tool_result in the
  # thread) instead of the analysis being dumped in as a spoofed user message.
  #
  # Screenshots are extracted on demand from the stored (720p) video — empirically
  # enough for Claude to OCR small on-screen text the video model couldn't. One
  # frame per issue with a parseable timestamp, flagged issues (needs_closer_look
  # / unreadable_text) prioritized to survive the per-response cap and captured at
  # top JPEG quality. Every media step is best-effort: no ffmpeg, a pruned video,
  # or a bad timestamp just yields text with fewer (or no) screenshots.
  class GetWalkthroughAnalysisTool < MCP::Tool
    tool_name "get_walkthrough_analysis"

    StoredVideoUnavailable = Class.new(StandardError)

    description <<~DESC.strip
      Get the full analysis of a walkthrough video the operator shared: the
      timestamped narration transcript, the topical sections, and every grounded
      issue (with severity, surface, the user's own words, and what's visible on
      screen). It also returns crisp screenshots of the flagged moments as images
      you can see directly — read exact on-screen text (error codes, IDs, URLs,
      config values, precise numbers) off those screenshots and use the EXACT
      characters; never guess text you can't actually read. Call this first when a
      walkthrough has finished analyzing, then propose an Epic or ask clarifying
      questions. `walkthrough_id` is the id from the orientation message.
    DESC

    input_schema(
      properties: {
        walkthrough_id: { type: "integer", description: "id of the analyzed walkthrough to review" }
      },
      required: %w[walkthrough_id]
    )

    class << self
      def call(server_context:, walkthrough_id: nil, **)
        chat_session = server_context.fetch(:chat_session)

        walkthrough = chat_session.video_walkthroughs.find_by(id: walkthrough_id)
        return Mcp::Tools.invalid("walkthrough not found in this chat: #{walkthrough_id.inspect}") unless walkthrough

        if walkthrough.analysis.blank?
          return Mcp::Tools.invalid(
            "Walkthrough ##{walkthrough.id} has no analysis yet — it may still be analyzing, or its analysis failed. " \
            "Nothing to review."
          )
        end

        frames = extract_frames(walkthrough)
        attached_keys = frames.map do |frame|
          Prompts::VideoWalkthroughReport.attachment_key(seconds: frame.seconds, title: frame.label)
        end

        report = Prompts::VideoWalkthroughReport.new(
          walkthrough: walkthrough, attached_issue_keys: attached_keys
        ).to_s

        MCP::Tool::Response.new(response_content(report, frames))
      end

      private

      # Text report first, then a labeled image block per extracted frame so the
      # agent can map each screenshot to its issue.
      def response_content(report, frames)
        content = [ { type: "text", text: report } ]
        frames.each do |frame|
          content << { type: "text", text: "Screenshot — #{frame.label} (at #{clock(frame.seconds)}):" }
          content << { type: "image", data: Base64.strict_encode64(frame.jpeg), mimeType: "image/jpeg" }
        end
        content
      end

      # One frame per issue timestamp, flagged issues prioritized within the cap
      # and captured at top JPEG quality. Best-effort — any failure yields [].
      def extract_frames(walkthrough)
        return [] unless walkthrough.file.attached?

        entries = frame_entries(walkthrough)
        return [] if entries.empty?

        with_local_video(walkthrough) do |path|
          Gemini::FrameExtractor.extract(video_path: path, timestamps: entries)
        end
      rescue StoredVideoUnavailable, StandardError => error
        Rails.logger.warn("[GetWalkthroughAnalysisTool] frame extraction failed: #{error.class}: #{error.message}")
        []
      end

      def frame_entries(walkthrough)
        entries = walkthrough.analysis_issues.filter_map do |issue|
          seconds = Gemini::FrameExtractor.parse_timestamp(issue["timestamp"])
          next unless seconds

          flagged = flagged_issue?(issue)
          {
            seconds: seconds,
            label: issue["title"].to_s,
            flagged: flagged,
            # Stored video is ~720p, so keep the default width (upscaling buys
            # nothing) but give flagged frames top JPEG quality for OCR.
            jpeg_quality: flagged ? Gemini::FrameExtractor::HIGH_JPEG_QUALITY : Gemini::FrameExtractor::JPEG_QUALITY
          }
        end
        prioritize_flagged(entries)
      end

      def flagged_issue?(issue)
        issue["needs_closer_look"] || issue["unreadable_text"].to_s.strip.present?
      end

      # Keep every flagged issue within the frame cap, fill remaining slots with
      # the earliest unflagged issues, then restore issue order.
      def prioritize_flagged(entries)
        cap = Gemini::FrameExtractor::MAX_FRAMES
        return entries if entries.size <= cap

        indexed = entries.each_with_index.to_a
        flagged, plain = indexed.partition { |entry, _index| entry[:flagged] }
        (flagged + plain).first(cap).sort_by { |_entry, index| index }.map(&:first)
      end

      def with_local_video(walkthrough)
        ext = File.extname(walkthrough.file.filename.to_s).presence || ".mp4"
        tmp = Tempfile.new([ "walkthrough-analysis", ext ], binmode: true)
        walkthrough.file.download { |chunk| tmp.write(chunk) }
        tmp.flush
        yield tmp.path
      rescue StandardError => error
        raise StoredVideoUnavailable, "#{error.class}: #{error.message}"
      ensure
        tmp&.close!
      end

      def clock(seconds)
        format("%d:%02d", seconds / 60, seconds % 60)
      end
    end
  end
end
