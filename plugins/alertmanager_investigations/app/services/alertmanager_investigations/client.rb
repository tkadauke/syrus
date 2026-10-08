require "json"
require "net/http"

module AlertmanagerInvestigations
  class Client
    Error = Class.new(StandardError)

    def initialize(configuration: Configuration.current)
      @configuration = configuration
    end

    def firing_alerts
      return [] if @configuration.base_url.blank?

      base_url = @configuration.base_url.end_with?("/") ? @configuration.base_url : "#{@configuration.base_url}/"
      uri = URI.join(base_url, "api/v2/alerts")
      uri.query = URI.encode_www_form(active: "true", silenced: "false", inhibited: "false")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@configuration.bearer_token}" if @configuration.bearer_token.present?

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 10
      ) { |http| http.request(request) }
      raise Error, "Alertmanager returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "Alertmanager returned invalid JSON: #{e.message}"
    end
  end
end
