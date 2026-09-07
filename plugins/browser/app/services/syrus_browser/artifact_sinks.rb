module SyrusBrowser
  # Where captured browser evidence (screenshots, for now) is filed,
  # independent of which browser session owns the call (see SessionContext).
  # Two axes, two decisions: SessionContext answers "which session do I
  # operate on"; ArtifactSinks answers "where does the evidence go."
  module ArtifactSinks
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
