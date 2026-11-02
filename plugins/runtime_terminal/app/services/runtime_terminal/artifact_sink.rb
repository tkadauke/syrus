module RuntimeTerminal
  # Persists terminal captures through the owning surface's established image
  # path: chat media for Coding Mode, or typed visual artifacts for a workflow
  # visual-review Run.
  class ArtifactSink
    Capture = Data.define(:id)

    def initialize(runtime_session)
      @runtime_session = runtime_session
    end

    def capture(bytes:, title:, metadata: {})
      return capture_for_workflow(bytes: bytes, title: title, metadata: metadata) if runtime_session.workflow

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

    def capture_for_workflow(bytes:, title:, metadata:)
      workflow = runtime_session.workflow
      run = runtime_session.run
      original_type = "visual_review_terminal_screenshot"
      stored_type = "#{original_type}_run_#{run.id}_#{next_capture_number(workflow, run)}"
      workflow.attach_visual_artifact!(
        type: stored_type,
        data: bytes,
        content_type: "image/png",
        filename: "#{stored_type}.png"
      )
      workflow.set_typed_artifact!(
        type: stored_type,
        title: title,
        original_type: original_type,
        renderer_type: :image_diff,
        payload: {
          "content_type" => "image/png",
          "byte_size" => bytes.bytesize,
          "image_url" => "/api/v1/app/workflows/#{workflow.id}/visual_artifact?type=#{CGI.escape(stored_type)}",
          "source" => "runtime_session",
          "captured_at" => Time.current.iso8601(3),
          "runtime_session_id" => runtime_session.id
        }.merge(metadata.to_h.stringify_keys),
        **TypedArtifactProvenance.for_run(run)
      )
      runtime_session.update!(
        latest_frame_url: "/api/v1/app/workflows/#{workflow.id}/visual_artifact?type=#{CGI.escape(stored_type)}",
        latest_frame_at: Time.current,
        metadata: runtime_session.metadata.merge("latest_frame_artifact_type" => stored_type)
      )
      Capture.new(id: stored_type)
    end

    def next_capture_number(workflow, run)
      Array(workflow.artifact("typed_artifacts")).count { |entry| entry["run_id"].to_i == run.id } + 1
    end

    def frame_url
      "/api/v1/app/chats/#{runtime_session.chat_session_id}/runtime_sessions/#{runtime_session.id}/frame"
    end
  end
end
