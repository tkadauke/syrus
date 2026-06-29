module ChatProviders
  class Base
    SessionCapture = Data.define(
      :provider,
      :session_id,
      :transcript_jsonl,
      :raw_provider_transcript,
      :normalized_messages,
      :missing_message
    )

    def initialize(chat:, runner: nil, image_paths: [], file_paths: [], env: {})
      @chat = chat
      @runner = runner
      @image_paths = Array(image_paths).compact
      @file_paths = Array(file_paths).compact
      @env = env || {}
    end

    def self.provider
      name.demodulize.underscore
    end

    def provider
      self.class.provider
    end

    def credentials_missing_message
      nil
    end

    def credentials_missing?
      false
    end

    def invoke(workspace_path:, prompt:, log_sink:, mcp_config:, resume_session_id:,
               stop_requested:, process_started:)
      raise NotImplementedError, "#{self.class.name} must implement #invoke"
    end

    def session_capture(result)
      return nil if result.session_id.blank?

      transcript = transcript_from_result(result)
      SessionCapture.new(
        provider: provider,
        session_id: result.session_id,
        transcript_jsonl: transcript,
        raw_provider_transcript: transcript,
        normalized_messages: normalized_messages_for(transcript),
        missing_message: nil
      )
    end

    private

    attr_reader :chat, :runner, :image_paths, :file_paths, :env

    def transcript_from_result(result)
      return result.transcript_jsonl if result.transcript_jsonl.present?
      return nil if result.transcript_path.blank? || !File.exist?(result.transcript_path)

      File.read(result.transcript_path)
    end

    def normalized_messages_for(transcript_jsonl)
      return [] if transcript_jsonl.blank?

      ClaudeTranscript.new(transcript_jsonl).events.filter_map do |event|
        case event.kind
        when :user_prompt
          { "role" => "user", "content" => event.data.fetch(:text).to_s }
        when :assistant_text
          { "role" => "assistant", "content" => event.data.fetch(:text).to_s }
        when :tool_use
          { "role" => "tool_use", "content" => event.data }
        when :tool_result
          { "role" => "tool_result", "content" => event.data }
        end
      end
    end
  end
end
