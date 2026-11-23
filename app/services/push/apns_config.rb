module Push
  # APNs credentials come from the environment so no Apple secret is stored in
  # the database: APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID and either
  # APNS_PRIVATE_KEY (PEM contents) or APNS_PRIVATE_KEY_PATH (a .p8 file).
  class ApnsConfig
    HOSTS = {
      "production" => "api.push.apple.com",
      "sandbox" => "api.sandbox.push.apple.com"
    }.freeze

    def self.from_env(env = ENV) = new(env)

    def initialize(env)
      @env = env
    end

    def key_id = @env["APNS_KEY_ID"].presence
    def team_id = @env["APNS_TEAM_ID"].presence
    def bundle_id = @env["APNS_BUNDLE_ID"].presence || "estate.syrus.app"

    def private_key_pem
      return @env["APNS_PRIVATE_KEY"].to_s.gsub("\\n", "\n").presence if @env["APNS_PRIVATE_KEY"].present?

      path = @env["APNS_PRIVATE_KEY_PATH"].presence
      File.read(path) if path && File.file?(path)
    end

    def configured? = key_id.present? && team_id.present? && private_key_pem.present?

    def host_for(environment) = HOSTS.fetch(environment.to_s) { HOSTS.fetch("production") }
  end
end
