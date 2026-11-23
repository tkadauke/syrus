require "json"
require "jwt"
require "openssl"

module PushNotifications
  # Minimal token-authenticated APNs HTTP/2 client. Returns a Result and never
  # raises for APNs-level rejections so the deliverer can decide whether to
  # disable the device or retry.
  class ApnsClient
    Response = Struct.new(:status, :body, keyword_init: true)

    Result = Struct.new(:status, :reason, keyword_init: true) do
      def success? = status == 200

      # The device token is permanently unusable: stop sending to it.
      def unregistered?
        status == 410 || (status == 400 && %w[BadDeviceToken DeviceTokenNotForTopic].include?(reason))
      end

      # Worth trying again later (APNs or the network is unhappy).
      def retryable?
        status.nil? || status == 429 || status >= 500 || reason == "ExpiredProviderToken"
      end
    end

    # APNs asks providers to refresh the JWT no more often than every 20
    # minutes and before it is an hour old.
    TOKEN_TTL = 40 * 60

    # Default transport: one HTTP/2 POST via httpx.
    class HttpxTransport
      def post(url, headers:, body:)
        response = HTTPX.with(timeout: { connect_timeout: 10, request_timeout: 20 }).post(url, headers: headers, body: body)
        return Response.new(status: nil, body: response.error.message) if response.is_a?(HTTPX::ErrorResponse)

        Response.new(status: response.status, body: response.body.to_s)
      end
    end

    def initialize(config: ApnsConfig.from_env, transport: HttpxTransport.new, clock: -> { Time.current })
      @config = config
      @transport = transport
      @clock = clock
    end

    def deliver(device_token:, environment:, payload:, collapse_id: nil)
      headers = {
        "authorization" => "bearer #{provider_token}",
        "apns-topic" => @config.bundle_id,
        "apns-push-type" => "alert",
        "apns-priority" => "10",
        "content-type" => "application/json"
      }
      headers["apns-collapse-id"] = collapse_id.to_s.byteslice(0, 64) if collapse_id.present?

      response = @transport.post(
        "#{@config.host_for(environment)}/3/device/#{device_token}",
        headers: headers,
        body: JSON.generate(payload)
      )
      @provider_token = nil if response.status == 403
      Result.new(status: response.status, reason: reason_from(response))
    rescue StandardError => e
      Result.new(status: nil, reason: "#{e.class}: #{e.message}".truncate(200))
    end

    private

    def provider_token
      now = @clock.call
      if @provider_token.nil? || now - @provider_token_issued_at > TOKEN_TTL
        @provider_token_issued_at = now
        key = OpenSSL::PKey::EC.new(@config.private_key_pem)
        @provider_token = JWT.encode({ iss: @config.team_id, iat: now.to_i }, key, "ES256", { kid: @config.key_id })
      end
      @provider_token
    end

    def reason_from(response)
      return response.body.to_s.truncate(200) if response.status.nil?
      return nil if response.status == 200

      JSON.parse(response.body.to_s)["reason"]
    rescue JSON::ParserError
      nil
    end
  end
end
