module VideoWalkthroughs
  # Validates a Gemini AI Studio API key, both saved (the /credentials "Test"
  # button) and pasted-but-unsaved (the setup sheet's paste-and-test flow).
  #
  # `models.list` is free and requires a working key, and the details carry
  # whether a video-capable flash model is actually available to this key's
  # project -- which is the whole point of configuring Gemini here. A key that
  # authenticates but has no video model is not a working key for this plugin,
  # so it reports red rather than green.
  class CredentialProbe
    CREDENTIAL = "gemini_api_key".freeze

    Result = ::CredentialProbe::Result

    def self.call(probe)
      user = probe.send(:user)
      return probe.send(:missing, "Gemini API key is not configured.") if user.gemini_api_key.blank?

      key(key: user.gemini_api_key)
    end

    def self.key(key:)
      key = key.to_s.strip
      return Result.new(credential: CREDENTIAL, ok: false, message: "Paste a key to test it.", details: {}) if key.blank?

      models = client_factory.call(api_key: key).list_models
      video_model = preferred_model(models)
      if video_model
        Result.new(credential: CREDENTIAL, ok: true,
                   message: "Gemini key is valid — #{video_model} is available for video analysis.",
                   details: { model: video_model, models_available: models.size })
      else
        Result.new(credential: CREDENTIAL, ok: false,
                   message: "The key works, but no video-capable Gemini flash model is available to this project.",
                   details: { models_available: models.size })
      end
    rescue Gemini::Client::AuthError
      Result.new(credential: CREDENTIAL, ok: false,
                 message: "Google rejected this key. Check that you copied the whole value from aistudio.google.com/apikey.", details: {})
    rescue Gemini::Client::RateLimited
      Result.new(credential: CREDENTIAL, ok: false,
                 message: "The key looks throttled right now (free-tier quota). Try again in a minute.", details: {})
    rescue Gemini::Client::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
      Result.new(credential: CREDENTIAL, ok: false,
                 message: "Could not reach Google to verify the key. Try again in a moment.", details: {})
    end

    # The SAME list the analysis job resolves against (resolve_video_model!),
    # so a key that validates green against a fallback model also analyzes with
    # that model.
    def self.preferred_model(models)
      Gemini::Client::VIDEO_MODELS.find { |candidate| models.any? { |name| name.start_with?(candidate) } }
    end

    # Test seam: specs swap the factory instead of stubbing HTTP.
    class << self
      attr_writer :client_factory

      def client_factory
        @client_factory ||= ->(api_key:) { Gemini::Client.new(api_key: api_key) }
      end
    end
  end
end
