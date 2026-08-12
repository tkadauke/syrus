require "fileutils"
require "tempfile"

module ChatSpeechToText
  module Providers
    class WhisperCpp < Base
      DEFAULT_TIMEOUT_SECONDS = 90

      # Minimal forward list for a compiled binary — no bundler/npm
      # config to scrub, just enough to resolve the executable and its
      # shared libs and to give it a sane scratch/home dir.
      ENV_FORWARD = %w[ PATH HOME TMPDIR LD_LIBRARY_PATH ].freeze

      def self.from_env
        executable = ENV["SYRUS_STT_WHISPER_CPP_EXECUTABLE"].to_s.strip.presence
        model = ENV["SYRUS_STT_WHISPER_CPP_MODEL"].to_s.strip.presence
        return unless executable && model

        new(
          executable: executable,
          model: model
        )
      end

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
        output = +""
        result = ProcessRunner.new(
          env: ProcessRunner.forwarded_env(ENV_FORWARD),
          command: [
            executable,
            "-m", model,
            "-f", audio.path,
            "-nt",
            "-np",
            "-otxt"
          ],
          chdir: File.dirname(audio.path),
          timeout: DEFAULT_TIMEOUT_SECONDS,
          kind: "chat_stt",
          display_command: display_command,
          on_output_chunk: ->(chunk) { output << chunk }
        ).run

        raise TranscriptionError, "Backend transcription timed out." if result.timed_out?
        unless result.success?
          raise TranscriptionError, output.presence || "whisper.cpp transcription failed"
        end

        text = extract_transcript(output, audio.path).strip
        raise TranscriptionError, "whisper.cpp returned an empty transcript" if text.blank?

        TranscriptionResult.new(text: text, segments: [], provider: "whisper_cpp", confidence: nil)
      ensure
        audio&.close! if audio.respond_to?(:close!) && audio.path != request&.audio&.path
      end

      private

      attr_reader :executable, :model

      # Omits the audio tempfile path — that's a local worker path with
      # no operator value, and we don't want it leaking into the admin
      # processes UI.
      def display_command
        "#{executable} -m #{model} -f [audio] -nt -np -otxt"
      end

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
