require "open3"

module VideoWalkthroughs
  module Gemini
    # Transcodes a walkthrough video to a compact H.264 mp4 for STORAGE. Empirical
    # testing showed Gemini analyzes the downscaled 720p mp4 exactly as well as
    # the full-resolution original (the narration carries the context), so the
    # kept artifact can be small: 720p, CRF 30, faststart. The original (crisp)
    # video is used for screenshot extraction first, then discarded — screenshots
    # from the source, a compact mp4 for storage + retry.
    #
    # ffmpeg lives in the runtime image; every failure mode (missing binary,
    # transcode error) is caught by the caller, which keeps the original video
    # rather than blocking. The command runs through an injectable seam.
    class VideoTranscoder
      # 720p is plenty for re-analysis and keeps stored videos small; taller
      # sources are scaled down, smaller ones are left alone (never upscale).
      TARGET_HEIGHT = 720
      CRF = 30

      class << self
        attr_writer :runner

        def runner
          @runner ||= ->(cmd) { o, s = Open3.capture2e(*cmd); [o, s] }
        end

        def available?
          _out, status = runner.call(["ffmpeg", "-version"])
          success?(status)
        rescue Errno::ENOENT
          false
        end

        def success?(status)
          status.respond_to?(:success?) ? status.success? : status.to_i.zero?
        end
      end

      # Transcode `input_path` to an mp4 at `output_path`. Returns true on
      # success (a non-empty mp4 exists), false otherwise. Never raises for a
      # transcode failure — the caller decides how to degrade.
      def self.to_compact_mp4(input_path:, output_path:)
        return false unless available?

        cmd = [
          "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
          "-i", input_path,
          # Downscale to TARGET_HEIGHT keeping aspect + even dimensions
          # (H.264 needs even width/height); never upscale.
          "-vf", "scale=-2:'min(#{TARGET_HEIGHT},ih)'",
          "-c:v", "libx264", "-preset", "veryfast", "-crf", CRF.to_s,
          "-c:a", "aac", "-b:a", "96k",
          "-movflags", "+faststart",
          output_path
        ]
        _output, status = runner.call(cmd)
        success?(status) && File.exist?(output_path) && File.size(output_path).positive?
      rescue StandardError => error
        Rails.logger.warn("[VideoWalkthroughs::Gemini::VideoTranscoder] transcode failed: #{error.class}: #{error.message}")
        false
      end
    end
  end
end
