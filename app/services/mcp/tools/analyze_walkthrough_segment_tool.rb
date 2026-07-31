require "mcp"
require "tempfile"

module Mcp::Tools
  # "Zoom in" on a walkthrough video: re-analyze one time range of an
  # already-uploaded Gemini file at full resolution to extract fine detail the
  # whole-video pass may have garbled (small text, fast clicks, exact error
  # wording). Gemini's Files API retains the upload ~48h, so a range of the
  # SAME file is analyzable with no re-upload; past retention (or if the file
  # is gone) the tool re-uploads the stored blob, and only gives up when even
  # that is pruned.
  class AnalyzeWalkthroughSegmentTool < MCP::Tool
    tool_name "analyze_walkthrough_segment"

    # A full-resolution re-analysis costs ~300 tokens/sec, so an unbounded
    # window (a caller passing the whole 15-min video) blows the free-tier
    # per-minute token window and 429s. Cap the clip length; the whole point of
    # this tool is a NARROW zoom, so 4 minutes is generous headroom over a real
    # "zoom into this moment" ask while staying well under the quota window.
    MAX_SEGMENT_SECONDS = 4 * 60

    # Raised when the stored blob can't be read on the re-upload path (blob
    # pruned/unreadable, disk error). Mapped to a clean tool error so an
    # ActiveStorage failure can't escape the tool's rescue chain.
    StoredVideoUnavailable = Class.new(StandardError)

    description <<~DESC.strip
      Re-analyze a specific time range of a walkthrough video at full resolution
      to extract fine detail the whole-video pass may have missed — exact error
      text, the precise sequence of clicks, small on-screen numbers. Use it for
      issues marked "needs a closer look", or whenever the user asks to zoom in
      on a moment. `start`/`end` are mm:ss or whole seconds; `focus` says what
      to extract (e.g. "the exact error text", "the sequence of clicks").
    DESC

    input_schema(
      properties: {
        walkthrough_id: { type: "integer", description: "id of the walkthrough to zoom into (the video_walkthrough_id from the analysis turn)" },
        start: { type: "string", description: "start of the range, mm:ss or whole seconds" },
        end: { type: "string", description: "end of the range, mm:ss or whole seconds" },
        focus: { type: "string", description: "what to extract from this range, e.g. \"the exact error text\" or \"the sequence of clicks\"" }
      },
      required: %w[walkthrough_id start end focus]
    )

    class << self
      # Test seam mirroring VideoWalkthroughAnalysisJob.client_factory: specs
      # swap in a fake Gemini client instead of stubbing Net::HTTP.
      attr_writer :client_factory

      def client_factory
        @client_factory ||= ->(api_key:) { Gemini::Client.new(api_key: api_key) }
      end

      def call(server_context:, walkthrough_id: nil, start: nil, focus: nil, **rest)
        chat_session = server_context.fetch(:chat_session)
        finish = rest[:end] || rest["end"]

        walkthrough = chat_session.video_walkthroughs.find_by(id: walkthrough_id)
        return Mcp::Tools.invalid("walkthrough not found in this chat: #{walkthrough_id.inspect}") unless walkthrough
        unless walkthrough.analyzed? && walkthrough.analysis.present?
          return Mcp::Tools.invalid("walkthrough #{walkthrough.id} has no completed analysis to zoom into")
        end

        start_seconds = Gemini::FrameExtractor.parse_timestamp(start)
        end_seconds = Gemini::FrameExtractor.parse_timestamp(finish)
        if start_seconds.nil? || end_seconds.nil?
          return Mcp::Tools.invalid("start and end must be mm:ss or whole seconds")
        end

        start_seconds, end_seconds, truncated = clamp(start_seconds, end_seconds, walkthrough.duration_seconds)
        return Mcp::Tools.invalid("end must be after start, and within the video") if start_seconds.nil?

        unless chat_session.user.gemini_configured?
          return Mcp::Tools.invalid("Gemini is not configured — add an API key under Credentials.")
        end

        client = client_factory.call(api_key: chat_session.user.gemini_api_key)
        client.resolve_video_model!

        resolved = active_file(client, walkthrough)
        if resolved.nil?
          return Mcp::Tools.invalid(
            "This video has expired — Gemini keeps uploads about 48 hours and the stored copy is gone. Record a fresh walkthrough to zoom in."
          )
        end
        file_uri, mime_type = resolved

        result = analyze_with_low_res_fallback(
          client, file_uri: file_uri, mime_type: mime_type,
          start_seconds: start_seconds, end_seconds: end_seconds, focus: focus
        )

        success = {
          walkthrough_id: walkthrough.id,
          range: clock_range(start_seconds, end_seconds),
          focus: focus.to_s,
          analysis: result
        }
        if truncated
          success[:note] =
            "The requested range exceeded the #{MAX_SEGMENT_SECONDS / 60}-minute zoom cap and was " \
            "truncated to #{clock_range(start_seconds, end_seconds)}. Zoom in on a shorter window for more."
        end
        Mcp::Tools.success(success)
      rescue StoredVideoUnavailable
        Mcp::Tools.invalid(
          "Could not read the stored video — it may have been pruned. Record a fresh walkthrough to zoom in."
        )
      rescue Gemini::Client::AuthError => e
        Mcp::Tools.invalid("Gemini rejected the API key: #{e.message} Check it under Credentials.")
      rescue Gemini::Client::RateLimited
        Mcp::Tools.invalid("Gemini's quota is busy right now (free-tier per-minute limits). Try the segment again in a minute.")
      rescue Gemini::Client::ConnectionError
        Mcp::Tools.invalid("Could not reach Gemini — try the segment again.")
      rescue Gemini::Client::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      # Run the segment at full resolution (the point of a zoom — LOW garbles
      # small text). If the free-tier per-minute window is blown, mirror the
      # whole-video job's degradation: retry ONCE at LOW resolution before
      # letting the RateLimited surface as the quota error. A second 429
      # propagates to the caller's rescue.
      def analyze_with_low_res_fallback(client, file_uri:, mime_type:, start_seconds:, end_seconds:, focus:)
        run_segment(client, file_uri, mime_type, start_seconds, end_seconds, focus, media_resolution: :default)
      rescue Gemini::Client::RateLimited
        run_segment(client, file_uri, mime_type, start_seconds, end_seconds, focus, media_resolution: :low)
      end

      def run_segment(client, file_uri, mime_type, start_seconds, end_seconds, focus, media_resolution:)
        client.analyze_segment(
          file_uri: file_uri,
          mime_type: mime_type,
          start_seconds: start_seconds,
          end_seconds: end_seconds,
          prompt: Prompts::VideoWalkthroughSegment.new(
            focus: focus, clock_range: clock_range(start_seconds, end_seconds)
          ).to_s,
          response_schema: Prompts::VideoWalkthroughSegment::RESPONSE_SCHEMA,
          media_resolution: media_resolution
        )
      end

      # Normalize the window: floor start at 0, cap end at the duration, keep
      # start strictly before end, then cap the LENGTH at MAX_SEGMENT_SECONDS so
      # a huge window can't blow the free-tier token budget at full resolution.
      # Returns [start, end, truncated?]; [nil, nil, false] when the window
      # collapses.
      def clamp(start_seconds, end_seconds, duration)
        start_seconds = 0 if start_seconds.negative?
        if duration.to_i.positive?
          end_seconds = [ end_seconds, duration.to_i ].min
          start_seconds = [ start_seconds, duration.to_i - 1 ].min
        end
        return [ nil, nil, false ] if end_seconds <= start_seconds

        truncated = false
        if end_seconds - start_seconds > MAX_SEGMENT_SECONDS
          end_seconds = start_seconds + MAX_SEGMENT_SECONDS
          truncated = true
        end

        [ start_seconds, end_seconds, truncated ]
      end

      def clock_range(start_seconds, end_seconds)
        "#{clock(start_seconds)}–#{clock(end_seconds)}"
      end

      def clock(seconds)
        format("%d:%02d", seconds / 60, seconds % 60)
      end

      # [file_uri, mime_type] usable for the segment call: the retained upload
      # if still fresh (with the mime of the bytes actually uploaded), otherwise
      # a fresh re-upload of the stored blob (with the blob's real content_type).
      # nil when neither is possible (past retention AND the blob was pruned).
      def active_file(client, walkthrough)
        return [ walkthrough.gemini_file_uri, walkthrough.gemini_upload_content_type ] if walkthrough.gemini_file_fresh?
        return nil unless walkthrough.file.attached?

        reupload(client, walkthrough)
      end

      def reupload(client, walkthrough)
        ext = File.extname(walkthrough.file.filename.to_s).presence || ".mp4"
        tmp = Tempfile.new([ "walkthrough-segment", ext ], binmode: true)
        # The stored blob is the source of truth for the re-uploaded bytes — use
        # its real content_type (the row's content_type could have drifted), and
        # stamp it so a later retained-file pass references the right mime.
        content_type = walkthrough.file.blob.content_type.presence || walkthrough.content_type
        download_blob(walkthrough, tmp)

        uploaded = File.open(tmp.path, "rb") do |io|
          client.upload_file(
            io: io,
            byte_size: File.size(tmp.path),
            content_type: content_type,
            display_name: walkthrough.display_title
          )
        end
        active = client.wait_until_active(uploaded.fetch("name"))
        walkthrough.update!(
          gemini_file_uri: active["uri"],
          gemini_file_active_at: Time.current,
          gemini_file_content_type: content_type
        )
        [ active.fetch("uri"), content_type ]
      ensure
        tmp&.close!
      end

      # Stream the stored blob to the tempfile. A missing/unreadable blob or disk
      # error raises ActiveStorage/StandardError here — map it to a clean tool
      # error instead of letting it escape the Gemini-only rescues above.
      def download_blob(walkthrough, tmp)
        walkthrough.file.download { |chunk| tmp.write(chunk) }
        tmp.flush
      rescue StandardError => error
        raise StoredVideoUnavailable, "#{error.class}: #{error.message}"
      end
    end
  end
end
