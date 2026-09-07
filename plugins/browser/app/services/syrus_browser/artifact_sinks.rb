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
    class ChatMedia
      def initialize(chat_session)
        @chat_session = chat_session
      end

      def capture(bytes:, content_type:, title:)
        return nil unless @chat_session

        ChatMediaLibrary.materialize_captured_image!(
          @chat_session,
          bytes: bytes,
          content_type: content_type,
          title: title
        )
      end
    end
  end
end
