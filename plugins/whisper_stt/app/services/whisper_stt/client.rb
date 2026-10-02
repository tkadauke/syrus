require "net/http"
require "tempfile"

module WhisperStt
  # HTTP client for whisper.cpp's whisper-server daemon.
  class Client
    class Error < StandardError; end
    class TimeoutError < Error; end
    class Unavailable < Error; end

    INFERENCE_PATH = "/inference".freeze
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 90
    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, EOFError,
      Net::HTTPBadResponse, OpenSSL::SSL::SSLError
    ].freeze

    def transcribe(audio:, content_type:, language: nil, prompt: nil)
      endpoint = PluginRuntime::Services.endpoint_for(RuntimeService.service_name)
      raise Unavailable, "whisper.cpp transcription failed" unless endpoint

      audio_file = materialize_audio(audio)
      request(Net::HTTP::Post, endpoint, INFERENCE_PATH, form: form_fields(audio_file, content_type, language, prompt))
    ensure
      audio_file&.close! if audio_file.respond_to?(:close!) && audio_file != audio
    end

    private

    def request(klass, endpoint, path, form:)
      uri = URI(endpoint)
      uri.path = path
      req = klass.new(uri)
      req.set_form(form, "multipart/form-data")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(req)
      end
      raise Error, error_message(response) unless response.is_a?(Net::HTTPSuccess)

      json(response)
    rescue Timeout::Error
      raise TimeoutError, "Backend transcription timed out."
    rescue *NETWORK_ERRORS => e
      raise Error, e.message.presence || "whisper.cpp transcription failed"
    ensure
      form&.each do |(_, value, _)|
        value.close if value.respond_to?(:close) && !value.closed?
      end
    end

    def form_fields(audio, content_type, language, prompt)
      fields = [
        [ "file", File.open(audio.path, "rb"), { filename: filename_for(content_type), content_type: content_type.presence || "application/octet-stream" } ],
        [ "response_format", "json" ]
      ]
      fields << [ "language", language ] if language.present?
      fields << [ "prompt", prompt ] if prompt.present?
      fields
    end

    def filename_for(content_type)
      extension = Rack::Mime::MIME_TYPES.invert[content_type.to_s].presence || ".bin"
      "dictation#{extension}"
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

    def error_message(response)
      body = response.body.to_s
      parsed = JSON.parse(body) rescue nil
      message = parsed.is_a?(Hash) ? parsed["error"] : nil
      message = message["message"] if message.is_a?(Hash)
      message.to_s.presence || body.presence || "whisper.cpp transcription failed"
    end

    def json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise Error, "whisper.cpp transcription failed"
    end
  end
end
