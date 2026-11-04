module SyrusBrowser
  require "digest"
  require "uri"
  # Where captured browser evidence (screenshots, for now) is filed,
  # independent of which browser session owns the call (see SessionContext).
  # Two axes, two decisions: SessionContext answers "which session do I
  # operate on"; ArtifactSinks answers "where does the evidence go."
  module ArtifactSinks
    class VisualReviewDraft
      MAX_CAPTURES_PER_RUN = 50

      def initialize(run)
        @run = run
      end

      def capture(bytes:, content_type:, title:, metadata: {})
        return nil unless title == "browser_screenshot capture"

        digest = Digest::SHA256.hexdigest(bytes)
        existing = @run.workflow.visual_evidences.find_by(run: @run, content_digest: digest)
        return existing if existing
        return nil if @run.workflow.visual_evidences.where(run: @run).count >= MAX_CAPTURES_PER_RUN

        evidence = @run.workflow.visual_evidences.create!(
          run: @run, step: @run.step,
          sequence: @run.workflow.visual_evidences.where(run: @run).maximum(:sequence).to_i + 1,
          status: "draft", captured_at: Time.current, content_digest: digest,
          page_identity: sanitize_page(metadata.to_h["page"] || metadata.to_h[:page]),
          viewport: metadata.to_h["viewport"] || metadata.to_h[:viewport] || {},
          device: metadata.to_h["device"] || metadata.to_h[:device],
          subject: metadata.to_h["subject"] || metadata.to_h[:subject]
        )
        evidence.image.attach(io: StringIO.new(bytes), filename: "visual-evidence-#{evidence.stable_id}.png", content_type:, identify: false)
        evidence
      end

      private

      def sanitize_page(page)
        page = page.to_h.stringify_keys
        uri = URI.parse(page["url"].to_s)
        safe_url = uri.path.presence || "/"
        safe_url += "##{uri.fragment}" if uri.fragment.present?
        { "url" => safe_url, "path" => safe_url, "title" => page["title"].to_s.truncate(200) }.compact_blank
      rescue URI::InvalidURIError
        { "title" => page["title"].to_s.truncate(200) }.compact_blank
      end
    end

    # The visual_review Run path's existing behavior: nothing is persisted
    # here at capture time. The image content returned to the agent is the
    # only output; the visual_review agent explicitly files durable evidence
    # itself via the separate submit_visual_artifact MCP tool. Keeping this a
    # true no-op is what keeps that path byte-for-byte unchanged.
    class Null
      def capture(**)
        nil
      end
    end

    # Coding Mode: a captured screenshot has no equivalent explicit "submit"
    # step, so the capture path itself files it as a chat-visible Document,
    # via the same Document/ChatAttachment recipe ChatMediaLibrary already
    # uses for pasted/uploaded chat images.
    #
    # When the capture is attributed to a RuntimeSession (the runtime_snapshot/
    # runtime_capture_artifact tools, or the Coding Mode Runtime panel's own
    # capture action), also stamp `latest_frame_url`/`latest_frame_at` so the
    # panel's periodic-screenshot polling (DOC-17's "Coding Mode Right
    # Sidebar") has something to point at -- otherwise those columns are
    # declared but never written.
    class ChatMedia
      def initialize(chat_session, runtime_session: nil)
        @chat_session = chat_session
        @runtime_session = runtime_session
      end

      def capture(bytes:, content_type:, title:)
        return nil unless @chat_session

        document = ChatMediaLibrary.materialize_captured_image!(
          @chat_session,
          bytes: bytes,
          content_type: content_type,
          title: title
        )
        stamp_latest_frame!(document) if @runtime_session
        document
      end

      private

      def stamp_latest_frame!(document)
        @runtime_session.update!(
          latest_frame_url: "/api/v1/app/chats/#{@chat_session.id}/runtime_sessions/#{@runtime_session.id}/frame",
          latest_frame_at: Time.current,
          metadata: @runtime_session.metadata.merge("latest_frame_document_id" => document.id)
        )
      end
    end
  end
end
