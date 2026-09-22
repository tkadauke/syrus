require "net/http"

module GitMirror
  # HTTP client for the mirror service. Translates its error codes into the
  # repository content contract's errors, so the provider can pass them
  # straight to the chain.
  class Client
    # The mirror has the repository on disk but no credential since it last
    # started. An Unavailable, so anything that does not handle it falls
    # through to the host as before; ContentProvider registers and retries.
    class Unregistered < RepositoryContent::Unavailable; end

    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 30
    # A resolve past max_age waits on a fetch.
    RESOLVE_TIMEOUT = 90
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, IOError, EOFError,
      Net::HTTPBadResponse, OpenSSL::SSL::SSLError
    ].freeze

    def initialize(endpoint:, token: Configuration.token)
      @endpoint = URI(endpoint)
      @token = token
    end

    def register(id, source)
      body = {
        vcs: source.vcs,
        url: source.url,
        username: source.username,
        password: source.password,
        expires_at: source.expires_at&.utc&.iso8601
      }.compact
      json(request(Net::HTTP::Put, "/v1/repositories/#{id}", body: body.to_json))
    end

    def remove(id)
      request(Net::HTTP::Delete, "/v1/repositories/#{id}")
      true
    rescue RepositoryContent::UnknownRevision
      true
    end

    def list
      stats.fetch("repositories")
    end

    # Every mirrored repository with its size and fetch state, plus the data
    # volume's capacity: { "repositories" => [...], "disk" => {...} }.
    def stats
      json(request(Net::HTTP::Get, "/v1/repositories"))
    end

    def resolve(id, ref, max_age:)
      json(request(Net::HTTP::Get, "/v1/repositories/#{id}/resolve", query: { ref: ref, max_age: max_age }, read_timeout: RESOLVE_TIMEOUT))
    end

    def tree(id, revision)
      json(request(Net::HTTP::Get, "/v1/repositories/#{id}/tree", query: { revision: revision })).fetch("entries")
    end

    # [bytes, content_id]
    def blob(id, revision, path)
      response = request(Net::HTTP::Get, "/v1/repositories/#{id}/blob", query: { revision: revision, path: path })
      [ response.body.to_s.b, response["X-Content-Id"] ]
    end

    def changes(id, base, head, patch: false)
      query = { base: base, head: head }
      query[:patch] = 1 if patch
      json(request(Net::HTTP::Get, "/v1/repositories/#{id}/changes", query: query)).fetch("changes")
    end

    def refs(id, pattern:, max_age:)
      json(request(Net::HTTP::Get, "/v1/repositories/#{id}/refs", query: { pattern: pattern, max_age: max_age }, read_timeout: RESOLVE_TIMEOUT)).fetch("refs")
    end

    def relation(id, base, head)
      json(request(Net::HTTP::Get, "/v1/repositories/#{id}/relation", query: { base: base, head: head })).fetch("relation")
    end

    private

    def request(klass, path, query: nil, body: nil, read_timeout: READ_TIMEOUT)
      uri = @endpoint.dup
      uri.path = path
      uri.query = URI.encode_www_form(query) if query
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      if body
        req["Content-Type"] = "application/json"
        req.body = body
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: read_timeout) do |http|
        http.request(req)
      end
      raise_for(response) unless response.is_a?(Net::HTTPSuccess)
      response
    rescue *NETWORK_ERRORS => e
      raise RepositoryContent::Unavailable, "git mirror: #{e.class}: #{e.message}"
    end

    def raise_for(response)
      error = JSON.parse(response.body.to_s)["error"] || {} rescue {}
      message = "git mirror: #{error['message'] || response.code}"
      case error["code"]
      when "not_found" then raise RepositoryContent::NotFound, message
      when "unknown_revision" then raise RepositoryContent::UnknownRevision, message
      when "unsupported" then raise RepositoryContent::Unsupported, message
      when "unregistered" then raise Unregistered, message
      # A repository the mirror has not been told about yet (it is registered
      # on the next tick) is not something it can answer; let the host.
      else raise RepositoryContent::Unavailable, message
      end
    end

    def json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      raise RepositoryContent::Unavailable, "git mirror: unreadable response: #{e.message}"
    end
  end
end
