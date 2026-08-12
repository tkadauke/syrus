require "net/http"
require "json"

module Gemini
  # Minimal client for the Google AI (generativelanguage.googleapis.com) API,
  # scoped to exactly what walkthrough analysis needs: key validation, Files
  # API upload (resumable protocol — videos are 100-500MB), file-state
  # polling, and one generateContent call with a JSON responseSchema.
  #
  # Auth is an AI Studio API key ONLY. The gemini-cli OAuth path talks to the
  # Code Assist API, which has no Files API — and reusing its OAuth client in
  # third-party apps is an enforced ToS violation. Keys are free
  # (aistudio.google.com/apikey) and validate with a free models.list ping.
  class Client
    BASE_URL = "https://generativelanguage.googleapis.com".freeze
    API_VERSION = "v1beta".freeze
    # Flash tier: free-tier eligible, native video+audio, structured outputs.
    DEFAULT_MODEL = "gemini-3.5-flash".freeze
    # A long video at full resolution can exceed the free-tier per-minute
    # token window (~300 tok/s × 900s ≈ 270K vs ~250K TPM). Past this length,
    # the analysis job retries at LOW resolution only if the full-res attempt
    # is actually rate-limited — full res stays the default because LOW
    # measurably garbles small on-screen text and numbers.
    LOW_RESOLUTION_FALLBACK_SECONDS = 12 * 60

    Error = Class.new(StandardError)
    # 400/401/403 — key invalid, revoked, or project-restricted.
    AuthError = Class.new(Error)
    # 429 — free-tier quota exhausted; caller should surface "try later".
    RateLimited = Class.new(Error)
    # Files API upload processed but the file landed in state FAILED.
    FileProcessingFailed = Class.new(Error)
    # Transport failures (DNS, timeouts, resets, TLS) — wrapped here so
    # callers rescuing Gemini::Client::Error catch EVERYTHING the client can
    # raise. Unwrapped Net::* escaping past the analysis job's rescue chain
    # stranded walkthroughs in "analyzing" forever (review finding).
    ConnectionError = Class.new(Error)

    TRANSPORT_ERRORS = [
      SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::EHOSTUNREACH, Errno::EPIPE, OpenSSL::SSL::SSLError, EOFError, IOError
    ].freeze

    # Flash-tier models that handle video, in preference order. The single
    # source of truth — CredentialProbe validates against this list and
    # resolve_video_model! picks from it at analysis time, so a key that
    # only exposes a fallback model both validates AND analyzes with it.
    VIDEO_MODELS = %w[gemini-3.5-flash gemini-3-flash-preview gemini-2.5-flash].freeze

    def initialize(api_key:, model: DEFAULT_MODEL)
      raise ArgumentError, "api_key required" if api_key.blank?

      @api_key = api_key
      @model = model
    end

    attr_reader :model

    # Cheap key validation: models.list is free and requires a working key.
    # Returns the list of model names (used to confirm a video-capable flash
    # model is actually available to this key's project).
    def list_models
      response = request(Net::HTTP::Get.new(uri_for("/#{API_VERSION}/models?pageSize=50")))
      json = parse!(response)
      Array(json["models"]).map { |m| m["name"].to_s.delete_prefix("models/") }
    end

    # Pick the best video-capable model this key's project actually exposes
    # and use it for subsequent calls. Validation-time and analysis-time model
    # choice go through the same list, so a key that validated green against
    # a fallback model can't fail analysis with a 404 on the default one.
    def resolve_video_model!
      models = list_models
      resolved = VIDEO_MODELS.find { |candidate| models.any? { |name| name.start_with?(candidate) } }
      raise Error, "no video-capable Gemini model is available to this project" unless resolved

      @model = resolved
    end

    # Files API resumable upload. Returns { "uri" =>, "name" =>, "state" => }.
    # The file enters PROCESSING server-side; callers poll wait_until_active
    # before generateContent can reference it.
    def upload_file(io:, byte_size:, content_type:, display_name:)
      start_uri = uri_for("/upload/#{API_VERSION}/files")
      start = Net::HTTP::Post.new(start_uri)
      start["X-Goog-Upload-Protocol"] = "resumable"
      start["X-Goog-Upload-Command"] = "start"
      start["X-Goog-Upload-Header-Content-Length"] = byte_size.to_s
      start["X-Goog-Upload-Header-Content-Type"] = content_type
      start["Content-Type"] = "application/json"
      start.body = { file: { display_name: display_name } }.to_json

      start_response = request(start)
      parse!(start_response) if start_response.code.to_i >= 400
      upload_url = start_response["x-goog-upload-url"]
      raise Error, "Gemini did not return a resumable upload URL" if upload_url.blank?

      upload_uri = URI.parse(upload_url)
      upload = Net::HTTP::Post.new(upload_uri)
      upload["X-Goog-Upload-Command"] = "upload, finalize"
      upload["X-Goog-Upload-Offset"] = "0"
      upload["Content-Length"] = byte_size.to_s
      upload.body_stream = io

      json = parse!(request(upload, uri: upload_uri, read_timeout: 600))
      json.fetch("file")
    end

    def file_state(name)
      response = request(Net::HTTP::Get.new(uri_for("/#{API_VERSION}/#{name}")))
      parse!(response)
    end

    # Poll until the uploaded video finishes server-side processing. Video
    # processing scales with length; a 15-min recording typically takes tens
    # of seconds. The interval is injectable so specs don't sleep.
    def wait_until_active(name, timeout: 300, interval: 5, sleeper: ->(s) { sleep(s) })
      deadline = Time.current + timeout
      loop do
        file = file_state(name)
        state = file["state"].to_s
        return file if state == "ACTIVE"
        raise FileProcessingFailed, "Gemini could not process the video (state FAILED)" if state == "FAILED"
        raise Error, "timed out waiting for Gemini to process the video" if Time.current >= deadline

        sleeper.call(interval)
      end
    end

    # One multimodal call: video (by Files API URI) + instruction, constrained
    # to a JSON responseSchema. `media_resolution` is `:default` (full — the
    # right choice for reading a screen; LOW measurably garbles small text and
    # numbers) or `:low` (a graceful-degradation fallback the caller uses only
    # when a long video actually blows the free-tier token window — see the
    # analysis job's retry ladder).
    #
    # `video_metadata`, when given, clips the analysis to a time window of the
    # SAME already-uploaded file (Files API retains it ~48h) — no re-upload.
    # It rides as a sibling of `file_data` on the video part; the wire shape is
    # `{ start_offset: "12s", end_offset: "30s" }` (Duration strings). We use
    # the proto snake_case field names to match the existing `file_data` /
    # `file_uri` fields — the generativelanguage REST endpoint accepts them.
    def generate_content(file_uri:, mime_type:, prompt:, response_schema:, media_resolution: :default, video_metadata: nil)
      video_part = { file_data: { file_uri: file_uri, mime_type: mime_type } }
      video_part[:video_metadata] = video_metadata if video_metadata.present?

      generate([ video_part, { text: prompt } ], response_schema: response_schema, media_resolution: media_resolution)
    end

    # Text-only structured completion — no Files API upload, no video part.
    # Scoped to short, synchronous, request-cycle uses (e.g. cadence-parsing
    # fallback) rather than the longer video analysis timeout.
    def generate_text(prompt:, response_schema:)
      generate([ { text: prompt } ], response_schema: response_schema, read_timeout: 30)
    end

    # Re-analyze one CLIP of an already-uploaded file — the "zoom in" path.
    # `start_seconds`/`end_seconds` bound the window; they render as Duration
    # strings ("12s") on the video part's `video_metadata`, so no re-upload is
    # needed while the file is still retained. Defaults to full resolution,
    # which is the point of a segment pass: read small text/fast action that a
    # whole-video pass may have garbled.
    def analyze_segment(file_uri:, mime_type:, start_seconds:, end_seconds:, prompt:, response_schema:, media_resolution: :default)
      generate_content(
        file_uri: file_uri,
        mime_type: mime_type,
        prompt: prompt,
        response_schema: response_schema,
        media_resolution: media_resolution,
        video_metadata: {
          start_offset: offset_string(start_seconds),
          end_offset: offset_string(end_seconds)
        }
      )
    end

    private

    def generate(parts, response_schema:, media_resolution: :default, read_timeout: 600)
      generation_config = {
        responseMimeType: "application/json",
        responseSchema: response_schema
      }
      generation_config[:mediaResolution] = "MEDIA_RESOLUTION_LOW" if media_resolution == :low

      body = {
        contents: [ { role: "user", parts: parts } ],
        generationConfig: generation_config
      }

      post = Net::HTTP::Post.new(uri_for("/#{API_VERSION}/models/#{@model}:generateContent"))
      post["Content-Type"] = "application/json"
      post.body = body.to_json

      json = parse!(request(post, read_timeout: read_timeout))
      # Long responses can arrive split across multiple text parts (the
      # official SDKs join them) — reading only parts[0] truncates a large
      # issues array mid-JSON and misreports a successful analysis as
      # malformed (review finding).
      response_parts = Array(json.dig("candidates", 0, "content", "parts"))
      text = response_parts.filter_map { |part| part["text"] }.join
      if text.blank?
        finish_reason = json.dig("candidates", 0, "finishReason").to_s
        detail = finish_reason.present? && finish_reason != "STOP" ? " (finish reason: #{finish_reason})" : ""
        raise Error, "Gemini returned an empty analysis#{detail}"
      end

      JSON.parse(text)
    rescue JSON::ParserError
      raise Error, "Gemini returned malformed JSON despite the response schema"
    end

    # Gemini's VideoMetadata offsets are protobuf Durations, serialized as a
    # decimal-seconds string with a trailing "s" (e.g. "12s").
    def offset_string(seconds)
      "#{seconds.to_i}s"
    end

    def uri_for(path)
      URI.parse("#{BASE_URL}#{path}")
    end

    def request(req, uri: req.uri, read_timeout: 60)
      req["x-goog-api-key"] = @api_key
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: read_timeout, open_timeout: 15) do |http|
        http.request(req)
      end
    rescue *TRANSPORT_ERRORS => error
      raise ConnectionError, "could not reach Gemini: #{error.class}: #{error.message}"
    end

    def parse!(response)
      code = response.code.to_i
      body = response.body.to_s
      json = body.present? ? (JSON.parse(body) rescue {}) : {}

      case code
      when 200..299 then json
      when 401, 403 then raise AuthError, api_message(json, "Gemini rejected this API key.")
      when 429 then raise RateLimited, api_message(json, "Gemini's quota is busy right now.")
      when 400
        message = api_message(json, "Gemini rejected the request.")
        raise message.match?(/API key/i) ? AuthError.new(message) : Error.new(message)
      else
        raise Error, api_message(json, "Gemini request failed (HTTP #{code}).")
      end
    end

    def api_message(json, fallback)
      json.dig("error", "message").presence || fallback
    end
  end
end
