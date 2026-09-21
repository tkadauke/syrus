require "net/http"
require "json"

module PluginRuntime
  # HTTP client for the runtime manager (plugins/plugin_runtime/container).
  #
  # Two failures are kept apart because they need opposite handling:
  #
  # - Refused: the manager's policy said no -- an image outside the allowlist,
  #   a malformed spec. That is a bug in the contributing plugin, and retrying
  #   every minute will not fix it, so it surfaces as the service's error.
  # - Unavailable: the manager could not be reached or failed. That is
  #   transient or operational, and the reconciler must not act on a partial
  #   view of the world while it lasts -- in particular it must not remove
  #   anything.
  class Client
    class Error < StandardError; end
    class Refused < Error; end
    class Unavailable < Error; end

    OPEN_TIMEOUT = 2
    # Ensure answers once the manager has asked the daemon; a pull runs in the
    # background and never holds the request open.
    READ_TIMEOUT = 15

    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, EOFError,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
    ].freeze

    def initialize(url:, token:)
      @base = URI(url)
      @token = token
    end

    def ensure_service(name, spec)
      request(Net::HTTP::Put, service_path(name), body: spec)
    end

    def status(name)
      request(Net::HTTP::Get, service_path(name))
    end

    def list
      Array(request(Net::HTTP::Get, "/v1/services")["services"])
    end

    # Keeps the service's volumes unless purge is set: disabling a plugin must
    # not throw away data that took hours to build; uninstalling it should.
    def remove(name, purge: false)
      request(Net::HTTP::Delete, service_path(name), query: purge ? "purge=true" : nil)
      nil
    end

    private

    def service_path(name)
      "/v1/services/#{ERB::Util.url_encode(name.to_s)}"
    end

    def request(klass, path, body: nil, query: nil)
      uri = @base.dup
      uri.path = path
      uri.query = query

      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(req)
      end
      parse(response)
    rescue *NETWORK_ERRORS => e
      raise Unavailable, "runtime manager unreachable: #{e.class}: #{e.message}"
    end

    def parse(response)
      code = response.code.to_i
      payload = response.body.present? ? JSON.parse(response.body) : {}

      case code
      when 200..299 then payload
      # 400 is the manager refusing a field it does not model -- a spec asking
      # for `privileged`, say. Like 422 it is the contributor's mistake, not
      # something that heals on retry.
      when 400, 422 then raise Refused, payload["error"].to_s
      else raise Unavailable, "runtime manager returned #{code}: #{payload['error']}"
      end
    rescue JSON::ParserError
      raise Unavailable, "runtime manager returned #{code} with a non-JSON body"
    end
  end
end
