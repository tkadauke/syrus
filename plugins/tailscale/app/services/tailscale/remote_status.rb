require "net/http"

module Tailscale
  # Fetches the tailscale-service container's /status, which proxies
  # tailscaled's local API. Shared by StatusPayload and HostAllowlist so
  # neither duplicates the HTTP call or the "no endpoint yet" handling.
  #
  # Returns nil when the container is not reachable at all (plugin disabled,
  # auth key not configured, container still pulling/starting) -- the same
  # "carry on without it" contract every PluginRuntime-backed service uses.
  class RemoteStatus
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5

    def self.call
      endpoint = PluginRuntime::Services.endpoint_for("tailscale")
      return nil unless endpoint

      uri = URI("#{endpoint}/status")
      response = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[Tailscale::RemoteStatus] fetch failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
