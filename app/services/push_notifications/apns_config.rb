module PushNotifications
  # APNs provider credentials, read from the environment so the .p8 key never
  # lands in the database. Delivery is a silent no-op until all four values
  # are present (see ios/docs/push-notifications.md).
  #
  #   SYRUS_APNS_KEY_ID       10-character key id of the APNs auth key
  #   SYRUS_APNS_TEAM_ID      10-character Apple Developer team id
  #   SYRUS_APNS_BUNDLE_ID    the app's bundle identifier (the apns-topic)
  #   SYRUS_APNS_PRIVATE_KEY  contents of the AuthKey_XXXX.p8 file (PEM);
  #                           literal "\n" sequences are accepted for
  #                           single-line secret stores
  class ApnsConfig
    HOSTS = {
      "production" => "https://api.push.apple.com",
      "sandbox" => "https://api.sandbox.push.apple.com"
    }.freeze

    attr_reader :key_id, :team_id, :bundle_id, :private_key_pem

    def self.from_env(env = ENV)
      new(
        key_id: env["SYRUS_APNS_KEY_ID"],
        team_id: env["SYRUS_APNS_TEAM_ID"],
        bundle_id: env["SYRUS_APNS_BUNDLE_ID"],
        private_key_pem: env["SYRUS_APNS_PRIVATE_KEY"]
      )
    end

    def initialize(key_id:, team_id:, bundle_id:, private_key_pem:)
      @key_id = key_id.to_s.strip
      @team_id = team_id.to_s.strip
      @bundle_id = bundle_id.to_s.strip
      @private_key_pem = private_key_pem.to_s.gsub("\\n", "\n").strip
    end

    def configured?
      [ key_id, team_id, bundle_id, private_key_pem ].none?(&:blank?)
    end

    def host_for(environment)
      HOSTS.fetch(environment.to_s, HOSTS["production"])
    end
  end
end
