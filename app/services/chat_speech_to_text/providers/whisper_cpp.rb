require "fileutils"
require "open3"
require "tempfile"
require "timeout"

module ChatSpeechToText
  module Providers
    class WhisperCpp < Base
      DEFAULT_TIMEOUT_SECONDS = 90

      # Baked into the app image by the whisper-build Dockerfile stage (see
      # Dockerfile:136-174). Only used when the corresponding env var is unset,
      # and only if the file actually exists — bare-metal/non-bundled installs
      # without these paths still fall through to nil (browser dictation).
      BUNDLED_EXECUTABLE_PATH = "/opt/whisper.cpp/whisper-cli"
      BUNDLED_MODEL_PATH = "/opt/whisper.cpp/models/ggml-base.en.bin"

      def self.from_env
        executable = ENV["SYRUS_STT_WHISPER_CPP_EXECUTABLE"].to_s.strip.presence || bundled_path(BUNDLED_EXECUTABLE_PATH)
        model = ENV["SYRUS_STT_WHISPER_CPP_MODEL"].to_s.strip.presence || bundled_path(BUNDLED_MODEL_PATH)
        return unless executable && model

        new(
          executable: executable,
          model: model
        )
      end

      def self.bundled_path(path)
        path if File.exist?(path)
      end
      private_class_method :bundled_path

      def initialize(executable:, model:)
        @executable = executable
        @model = model
      end

      def batch?
        true
      end

      def streaming?
        false
      end

      def transcribe_batch(request)
        audio = materialize_audio(request.audio)
        stdout, stderr, status = Timeout.timeout(DEFAULT_TIMEOUT_SECONDS, TranscriptionError, "Backend transcription timed out.") do
          Open3.capture3(
            executable,
            "-m", model,
            "-f", audio.path,
            "-nt",
            "-np",
            "-otxt",
            stdin_data: "",
            binmode: true
          )
        end
        unless status.success?
          raise TranscriptionError, stderr.presence || stdout.presence || "whisper.cpp transcription failed"
        end

        text = extract_transcript(stdout, audio.path).strip
        raise TranscriptionError, "whisper.cpp returned an empty transcript" if text.blank?

        TranscriptionResult.new(text: text, segments: [], provider: "whisper_cpp", confidence: nil)
      ensure
        audio&.close! if audio.respond_to?(:close!) && audio.path != request&.audio&.path
      end

      private

      attr_reader :executable, :model

      def materialize_audio(audio)
        return audio if audio.respond_to?(:path) && audio.path.present?

        tmp = Tempfile.new([ "syrus-stt-audio", ".bin" ])
        tmp.binmode
        audio.rewind if audio.respond_to?(:rewind)
        IO.copy_stream(audio, tmp)
        tmp.rewind
        tmp
      end

      def extract_transcript(stdout, audio_path)
        output_path = "#{audio_path}.txt"
        return File.read(output_path) if File.exist?(output_path)

        stdout.to_s
      ensure
        FileUtils.rm_f(output_path) if output_path
      end
    end
  end
end
