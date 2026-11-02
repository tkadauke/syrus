module RuntimeTerminal
  # Persists terminal captures through the same chat-media library used by
  # other Coding Mode image producers, then points the access-controlled
  # Runtime frame endpoint at the newly-created Document.
  class ArtifactSink
    def initialize(runtime_session)
      @runtime_session = runtime_session
    end

    def capture(bytes:, title:)
      document = ChatMediaLibrary.materialize_captured_image!(
        runtime_session.chat_session,
        bytes: bytes,
        content_type: "image/png",
        title: title
      )
      runtime_session.update!(
        latest_frame_url: frame_url,
        latest_frame_at: Time.current,
        metadata: runtime_session.metadata.merge("latest_frame_document_id" => document.id)
      )
      document
    end

    private

    attr_reader :runtime_session

    def frame_url
      "/api/v1/app/chats/#{runtime_session.chat_session_id}/runtime_sessions/#{runtime_session.id}/frame"
    end
  end
end
