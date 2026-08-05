module ChatSpeechToText
  module AudioConstraints
    ALLOWED_CONTENT_TYPES = %w[
      audio/webm
      audio/mp4
      audio/mpeg
      audio/wav
      audio/x-wav
      audio/ogg
    ].freeze
    MAX_BYTES = 10.megabytes
    MAX_DURATION_SECONDS = 120
  end
end
