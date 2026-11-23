require "json"
require "jwt"

module Push
  # Minimal APNs provider-API client (token auth). APNs requires HTTP/2, which
  # Net::HTTP does not speak, so the default transport runs `curl --http2`
  # through ProcessRunner. Tests inject a transport.
  class ApnsClient
    Response = Struct.new(:status, :body, keyword_init: true) do
      def success? = status == 200

      def reason = (JSON.parse(body.to_s)["reason"] rescue nil)

      # Tokens APNs says are permanently dead and must stop receiving pushes.
      def invalid_token?
        status == 410 || (status == 400 && %w[BadDeviceToken DeviceTokenNotForTopic].include?(reason))
      end
    end

    JWT_TTL = 40.minutes

    class CurlTransport
      def call(url:, headers:, body:)
        config = Tempfile.new("apns-curl")
        config.write(headers.map { |k, v| "header = \"#{k}: #{v}\"\n" }.join)
        config.flush
        result = ProcessRunner.new(
          env: {}, command: [ "curl", "--silent", "--http2", "--max-time", "15", "--config", config.path,
                              "--request", "POST", "--data-binary", "@-", "--write-out", "\n%{http_code}", url ],
          stdin_data: body, mounts: ProcessRunner.mounts(Dir.tmpdir, read_write: [ Dir.tmpdir ]),
          network: "prepare", timeout: 30, kind: "diagnostic",
          display_command: [ "curl", "--http2", url ]
        ).capture
        out = result.stdout.to_s
        payload, _, code = out.rpartition("\n")
        Response.new(status: code.to_i, body: payload)
      ensure
        config&.close!
      end
    end

    def initialize(config: ApnsConfig.from_env, transport: CurlTransport.new, clock: -> { Time.now })
      @config = config
      @transport = transport
      @clock = clock
    end

    def configured? = @config.configured?

    def deliver(device:, alert:, payload: {}, collapse_id: nil)
      raise "APNs is not configured" unless configured?

      aps = { "alert" => alert, "sound" => "default" }
      aps["badge"] = payload.delete(:badge) if payload.key?(:badge)
      headers = {
        "authorization" => "bearer #{provider_token}",
        "apns-topic" => device.bundle_id.presence || @config.bundle_id,
        "apns-push-type" => "alert",
        "content-type" => "application/json"
      }
      headers["apns-collapse-id"] = collapse_id.to_s[0, 64] if collapse_id.present?
      @transport.call(
        url: "https://#{@config.host_for(device.environment)}/3/device/#{device.token}",
        headers: headers,
        body: JSON.generate(payload.stringify_keys.merge("aps" => aps))
      )
    end

    def provider_token
      now = @clock.call
      return @token if @token && @token_issued_at && now - @token_issued_at < JWT_TTL

      key = OpenSSL::PKey::EC.new(@config.private_key_pem)
      @token_issued_at = now
      @token = JWT.encode({ iss: @config.team_id, iat: now.to_i }, key, "ES256", { kid: @config.key_id })
    end
  end
end
