require "openssl"

module Apns
  # Token-based (.p8) APNs credentials, read from the environment so that no
  # secret is stored in the database:
  #
  #   SYRUS_APNS_TEAM_ID    Apple Developer Team ID
  #   SYRUS_APNS_KEY_ID     Key ID of the APNs auth key
  #   SYRUS_APNS_AUTH_KEY   PEM contents of the .p8 key (\n escapes allowed), or
  #   SYRUS_APNS_AUTH_KEY_PATH  path to the .p8 file
  #   SYRUS_APNS_TOPIC      default bundle id (apns-topic) for devices that do
  #                         not report one
  class Configuration
    HOSTS = {
      "production" => "https://api.push.apple.com",
      "sandbox" => "https://api.sandbox.push.apple.com"
    }.freeze

    attr_reader :team_id, :key_id, :private_key_pem, :default_topic

    def self.from_env(env = ENV)
      pem = env["SYRUS_APNS_AUTH_KEY"].to_s.gsub("\\n", "\n").presence
      path = env["SYRUS_APNS_AUTH_KEY_PATH"].presence
      pem ||= File.read(path) if path && File.file?(path)
      new(
        team_id: env["SYRUS_APNS_TEAM_ID"],
        key_id: env["SYRUS_APNS_KEY_ID"],
        private_key_pem: pem,
        default_topic: env["SYRUS_APNS_TOPIC"]
      )
    end

    def initialize(team_id:, key_id:, private_key_pem:, default_topic: nil)
      @team_id = team_id.to_s.strip.presence
      @key_id = key_id.to_s.strip.presence
      @private_key_pem = private_key_pem.to_s.strip.presence
      @default_topic = default_topic.to_s.strip.presence
    end

    def configured?
      team_id && key_id && private_key_pem ? true : false
    end

    def private_key
      OpenSSL::PKey::EC.new(private_key_pem)
    end

    def host_for(environment)
      HOSTS.fetch(environment.to_s) { HOSTS.fetch("production") }
    end
  end
end
