require "mcp"
require "tempfile"

module Mcp::Tools
  # Pull ONE crisp still from a walkthrough video at any moment so the chat agent
  # (Claude) can read small on-screen text the video model couldn't — exact error
  # codes, IDs, URLs, config values, precise numbers. This is the on-demand half
  # of the OCR handoff: the analysis turn already auto-attaches stills at the
  # flagged issue timestamps, but the agent can call this to read a moment it
  # decides matters (a different timestamp, or a re-grab).
  #
  # Delivery: the frame comes back as a native MCP `image` content block
  # (Mcp::Tools.image_result). Claude Code renders that into the agent's
  # context as an actual image it sees THIS turn — no Gemini round-trip, no
  # workspace file, no extra Read call. 720p (the compact stored blob) is
  # empirically enough for Claude to OCR, so this extracts at FrameExtractor's
  # default width rather than the higher OCR-grade width the analysis job uses on
  # the crisp source.
  class ReadWalkthroughFrameTool < MCP::Tool
    tool_name "read_walkthrough_frame"

    # Raised when the stored blob can't be read (pruned/unreadable, disk error).
    # Mapped to a clean tool error so an ActiveStorage failure can't escape.
    StoredVideoUnavailable = Class.new(StandardError)

    description <<~DESC.strip
      Capture one crisp screenshot from a walkthrough video at a given moment and
      return it as an image you can see directly — so you can READ small on-screen
      text the video model couldn't: exact error codes, IDs, URLs, config values,
      precise numbers. You read still images far more reliably than the video
      model reads video, so never guess text you can pull with this instead. Use
      it for a "needs a closer look" issue whose auto-attached screenshot isn't
      enough, or any moment whose exact text matters. `timestamp` is mm:ss or
      whole seconds; it is clamped to the video's length when that length is
      known (some recorder blobs report no measurable duration, so a time past
      the end can't always be clamped).
    DESC

    input_schema(
      properties: {
        walkthrough_id: { type: "integer", description: "id of the walkthrough to screenshot (the video_walkthrough_id from the analysis turn)" },
        timestamp: { type: "string", description: "the moment to capture, mm:ss or whole seconds" }
      },
      required: %w[walkthrough_id timestamp]
    )

    class << self
      def call(server_context:, walkthrough_id: nil, timestamp: nil, **)
        chat_session = server_context.fetch(:chat_session)

        walkthrough = chat_session.video_walkthroughs.find_by(id: walkthrough_id)
        return Mcp::Tools.invalid("walkthrough not found in this chat: #{walkthrough_id.inspect}") unless walkthrough

        seconds = Gemini::FrameExtractor.parse_timestamp(timestamp)
        return Mcp::Tools.invalid("timestamp must be mm:ss or whole seconds") if seconds.nil?

        seconds = clamp(seconds, walkthrough.duration_seconds)

        unless walkthrough.file.attached?
          return Mcp::Tools.invalid(
            "This video has expired — Syrus prunes stored walkthroughs after a retention window and this one's video is gone. Record a fresh walkthrough to screenshot it."
          )
        end

        frame = extract_frame(walkthrough, seconds)
        return Mcp::Tools.invalid(frameless_error(walkthrough, seconds)) if frame.nil?

        Mcp::Tools.image_result(
          jpeg: frame.jpeg,
          text: "Screenshot from walkthrough ##{walkthrough.id} at #{clock(seconds)}. " \
                "Read any on-screen text directly off this image and use the exact characters you see — " \
                "don't guess anything you can't actually read."
        )
      rescue StoredVideoUnavailable
        Mcp::Tools.invalid(
          "Couldn't read the stored video — it may have been pruned. Record a fresh walkthrough to screenshot it."
        )
      end

      private

      def extract_frame(walkthrough, seconds)
        with_local_video(walkthrough) do |path|
          Gemini::FrameExtractor.extract(
            video_path: path,
            timestamps: [ { seconds: seconds, label: "walkthrough #{walkthrough.id} @ #{clock(seconds)}" } ]
          ).first
        end
      end

      def with_local_video(walkthrough)
        ext = File.extname(walkthrough.file.filename.to_s).presence || ".mp4"
        tmp = Tempfile.new([ "walkthrough-frame", ext ], binmode: true)
        download_blob(walkthrough, tmp)
        yield tmp.path
      ensure
        tmp&.close!
      end

      # Stream the stored blob to the tempfile. A missing/unreadable blob or disk
      # error raises here — map it to a clean tool error instead of letting an
      # ActiveStorage failure escape the tool's rescue.
      def download_blob(walkthrough, tmp)
        walkthrough.file.download { |chunk| tmp.write(chunk) }
        tmp.flush
      rescue StandardError => error
        raise StoredVideoUnavailable, "#{error.class}: #{error.message}"
      end

      # Floor negatives at 0. When the duration is KNOWN (positive), cap at the
      # last whole second — a frame exactly at the duration may not exist,
      # mirroring the segment tool's start clamp. When it's UNKNOWN (nil /
      # non-positive — webm MediaRecorder blobs commonly can't report a length,
      # so the client omits it and the row persists nil) we CAN'T cap: pass the
      # time through and let a frameless extraction be diagnosed honestly below.
      def clamp(seconds, duration)
        seconds = 0 if seconds.negative?
        if duration.to_i.positive?
          seconds = [ seconds, [ duration.to_i - 1, 0 ].max ].min
        end
        seconds
      end

      # Honest diagnosis for a frameless grab. With a KNOWN duration we already
      # clamped, so a missing frame points at ffmpeg/codec trouble. With an
      # UNKNOWN duration we couldn't clamp, so the requested time may simply be
      # past the end — say so (and name the time) instead of blaming ffmpeg.
      def frameless_error(walkthrough, seconds)
        base = "Couldn't capture a screenshot at #{clock(seconds)}"
        if walkthrough.duration_seconds.to_i.positive?
          "#{base} — the frame grab failed (ffmpeg unavailable, or an unsupported/corrupt video)."
        else
          "#{base} — the frame grab produced nothing. This video's duration is unknown, so " \
            "#{clock(seconds)} may be past its end; try an earlier timestamp. " \
            "(Also possible: ffmpeg is unavailable, or the video is unsupported/corrupt.)"
        end
      end

      def clock(seconds)
        format("%d:%02d", seconds / 60, seconds % 60)
      end
    end
  end
end
