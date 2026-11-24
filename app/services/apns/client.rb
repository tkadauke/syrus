require "json"
require "jwt"

module Apns
  # Minimal APNs provider-API client (HTTP/2, token auth).
  #
  # The transport is injectable (`call(url:, headers:, body:) -> [status, body]`)
  # so everything except the socket is covered by specs without Apple.
  class Client
    # APNs asks providers not to mint a new JWT more than once per 20 minutes
    # and rejects tokens older than 60 minutes.
    TOKEN_TTL = 50 * 60

    Result = Struct.new(:status, :reason, :apns_id, keyword_init: true) do
      def success? = status == 200
      # The token is permanently useless; stop sending to it.
      def invalid_token?
        status == 410 || %w[BadDeviceToken Unregistered DeviceTokenNotForTopic].include?(reason)
      end
    end

    class HttpxTransport
      def call(url:, headers:, body:)
        response = HTTPX.with(headers: headers, timeout: { connect_timeout: 10, request_timeout: 20 }).post(url, body: body)
        raise response.error if response.is_a?(HTTPX::ErrorResponse)

        [ response.status, response.body.to_s, response.headers["apns-id"] ]
      end
    end

    def initialize(configuration: Configuration.from_env, transport: HttpxTransport.new, clock: -> { Time.now })
      @configuration = configuration
      @transport = transport
      @clock = clock
      @mutex = Mutex.new
    end

    def configured? = @configuration.configured?

    def deliver(device:, payload:, collapse_id: nil)
      topic = device.bundle_id.presence || @configuration.default_topic
      headers = {
        "authorization" => "bearer #{provider_token}",
        "apns-topic" => topic,
        "apns-push-type" => "alert",
        "apns-priority" => "10",
        "content-type" => "application/json"
      }
      headers["apns-collapse-id"] = collapse_id.to_s.byteslice(0, 64) if collapse_id.present?

      url = "#{@configuration.host_for(device.apns_environment)}/3/device/#{device.token}"
      status, body, apns_id = @transport.call(url: url, headers: headers, body: JSON.generate(payload))
      reason = (JSON.parse(body.to_s)["reason"] rescue nil) unless status == 200 # rubocop:disable Style/RescueModifier
      Result.new(status: status, reason: reason, apns_id: apns_id)
    end

    private

    def provider_token
      @mutex.synchronize do
        now = @clock.call.to_i
        if @token.nil? || now - @token_issued_at >= TOKEN_TTL
          @token_issued_at = now
          @token = JWT.encode(
            { iss: @configuration.team_id, iat: now },
            @configuration.private_key,
            "ES256",
            { kid: @configuration.key_id }
          )
        end
        @token
      end
    end
  end
end
