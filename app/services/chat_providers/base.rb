module ChatProviders
  class Base
    SessionCapture = Data.define(
      :provider,
      :session_id,
      :transcript_jsonl,
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
      name.to_s.demodulize.underscore.presence || "unknown"
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
          { "role" => "user", "content" => event.data.fetch(:text).to_s }.merge(sidechain_tags(event))
        when :assistant_text
          { "role" => "assistant", "content" => event.data.fetch(:text).to_s }.merge(sidechain_tags(event))
        when :tool_use
          { "role" => "tool_use", "content" => event.data }.merge(sidechain_tags(event))
        when :tool_result
          { "role" => "tool_result", "content" => event.data }.merge(sidechain_tags(event))
        end
      end
    end

    # Carries the sidechain (subagent) marker and its spawning tool_use id
    # forward from ClaudeTranscript's per-event data onto the normalized
    # message, so a consumer can reconstruct which top-level tool call a
    # nested subagent turn belongs to without restructuring the flat list.
    # Omitted entirely for ordinary top-level messages (the vast majority)
    # to keep the normalized shape unchanged for non-subagent transcripts.
    def sidechain_tags(event)
      return {} unless event.data[:sidechain] == true

      { "sidechain" => true, "parent_tool_use_id" => event.data[:parent_tool_use_id] }
    end
  end
end
