require "net/http"

module PluginRuntime
  # Kubernetes, or any install without the runtime manager: the operator
  # deploys each service and tells Syrus where it is. Nothing is started or
  # stopped here -- Syrus is not given the power to create workloads -- so the
  # driver only reads each service's address from configuration and checks
  # that it answers.
  #
  # Checking matters even though nothing is managed: endpoint_for only hands
  # out a service that passed its health check, in either mode, so a
  # misconfigured or down service degrades to the caller's fallback instead of
  # failing every request that tries it.
  class ExternalDriver
    PROBE_TIMEOUT = 2

    def initialize(configuration:, probe: nil)
      @configuration = configuration
      @probe = probe || method(:http_probe)
    end

    def mode = "external"

    def reconcile(desired)
      desired.each { |entry| StatusCache.write(check(entry)) }
    end

    private

    def check(entry)
      url = @configuration.external_url(entry.name)
      unless url
        return status(entry, state: "unconfigured",
                             error: "set #{Configuration.external_url_key(entry.name)} to this service's address")
      end

      endpoint = url.chomp("/")
      path = health_path(entry)
      if path && (failure = @probe.call("#{endpoint}#{path}"))
        return status(entry, state: "unhealthy", endpoint: endpoint, error: failure)
      end

      status(entry, state: "running", endpoint: endpoint)
    end

    def health_path(entry)
      entry.provider.service_spec.deep_symbolize_keys.dig(:healthcheck, :path)
    rescue StandardError
      nil
    end

    def status(entry, **attributes)
      ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: mode, **attributes)
    end

    # Returns nil when healthy, otherwise a reason.
    def http_probe(url)
      uri = URI(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: PROBE_TIMEOUT, read_timeout: PROBE_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri))
      end
      response.code.to_i < 400 ? nil : "health check returned #{response.code}"
    rescue *Client::NETWORK_ERRORS, URI::InvalidURIError => e
      "health check failed: #{e.class}: #{e.message}"
    end
  end
end
