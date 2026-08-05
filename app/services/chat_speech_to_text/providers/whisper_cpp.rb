module ChatSpeechToText
  module Providers
    class WhisperCpp < Base
      def self.from_env
        executable = ENV["SYRUS_STT_WHISPER_CPP_EXECUTABLE"].to_s.strip.presence
        model = ENV["SYRUS_STT_WHISPER_CPP_MODEL"].to_s.strip.presence
        return unless executable && model

        new(
          executable: executable,
          model: model,
          streaming: ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_STT_BACKEND_STREAMING"])
        )
      end

      def initialize(executable:, model:, streaming: false)
        @executable = executable
        @model = model
        @streaming = streaming
      end

      def batch?
        true
      end

      def streaming?
        @streaming
      end

      private

      attr_reader :executable, :model
    end
  end
end
