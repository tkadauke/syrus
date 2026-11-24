require "net/http"
require "json"

module RuntimeImages
  module OciRegistry
    # Minimal OCI distribution HTTP client implementing the registry token
    # flow. Every request is made as one role against one repository, and any
    # bearer token is requested for exactly that repository and that role's
    # actions, so a token can never be replayed against another namespace.
    class HttpClient
      Response = Data.define(:status, :headers, :body) do
        def success? = status.between?(200, 299)
        def header(name) = headers[name.to_s.downcase]
      end

      class AuthenticationFailed < ProviderError
        attr_reader :status

        def initialize(message, status: nil)
          super(message)
          @status = status
        end
      end

      TOKEN_SKEW = 30

      def initialize(configuration)
        @configuration = configuration
        @tokens = {}
        @mutex = Mutex.new
      end

      def request(role:, repository:, method:, path:, headers: {}, body: nil, actions: nil)
        actions ||= Configuration::ROLE_ACTIONS.fetch(role)
        auth = cached_authorization(role, repository, actions)
        response = perform(method, path, headers, body, auth)
        return response unless response.status == 401
        challenge = parse_challenge(response.header("www-authenticate"))
        auth = authorization_for(challenge, role, repository, actions)
        response = perform(method, path, headers, body, auth)
        if response.status == 401
          raise AuthenticationFailed.new("registry rejected #{role} credentials for #{repository}", status: 401)
        end
        response
      end

      # Mints a bearer token and returns [token, expires_at] without caching,
      # for handing a scoped credential to a workload.
      def mint_token(role:, repository:, actions:)
        challenge = parse_challenge(perform(:get, "/v2/", {}, nil, nil).then { |r| r.header("www-authenticate") })
        raise AuthenticationFailed, "registry does not use token authentication" unless challenge&.fetch(:scheme) == "bearer"
        fetch_token(challenge, role, repository, actions)
      end

      def ping
        perform(:get, "/v2/", {}, nil, nil)
      end

      def discovered_challenge
        parse_challenge(ping.header("www-authenticate"))
      end

      private

      def cached_authorization(role, repository, actions)
        @mutex.synchronize do
          entry = @tokens[[role, repository, actions]]
          entry && entry[:expires_at] > Time.current + TOKEN_SKEW ? "Bearer #{entry[:token]}" : nil
        end
      end

      def authorization_for(challenge, role, repository, actions)
        raise AuthenticationFailed, "registry requires authentication but offered no usable challenge" unless challenge
        case challenge[:scheme]
        when "bearer"
          token, expires_at = fetch_token(challenge, role, repository, actions)
          @mutex.synchronize { @tokens[[role, repository, actions]] = { token: token, expires_at: expires_at } }
          "Bearer #{token}"
        when "basic"
          @configuration.credential_for(role).basic_header
        else
          raise AuthenticationFailed, "unsupported registry authentication scheme #{challenge[:scheme].inspect}"
        end
      end

      def fetch_token(challenge, role, repository, actions)
        realm = URI.parse(challenge.fetch(:realm) { raise AuthenticationFailed, "bearer challenge has no realm" })
        if @configuration.secure? && realm.scheme != "https"
          raise AuthenticationFailed, "refusing to send credentials to a non-https token realm"
        end
        query = URI.decode_www_form(realm.query.to_s)
        query << ["service", challenge[:service]] if challenge[:service]
        query << ["scope", "repository:#{repository}:#{actions.join(',')}"]
        realm.query = URI.encode_www_form(query)
        response = raw_request(realm, :get, { "Authorization" => @configuration.credential_for(role).basic_header }, nil)
        unless response.success?
          raise AuthenticationFailed.new("token service denied #{role} access to #{repository} (HTTP #{response.status})", status: response.status)
        end
        payload = JSON.parse(response.body)
        token = payload["token"] || payload["access_token"]
        raise AuthenticationFailed, "token service returned no token" if token.blank?
        expires_in = payload["expires_in"].to_i
        expires_in = 60 if expires_in <= 0
        [token, Time.current + expires_in]
      rescue JSON::ParserError
        raise AuthenticationFailed, "token service returned an invalid response"
      end

      def parse_challenge(header)
        return nil if header.blank?
        scheme, rest = header.split(" ", 2)
        params = rest.to_s.scan(/(\w+)="([^"]*)"/).to_h { |k, v| [k.downcase.to_sym, v] }
        params.merge(scheme: scheme.downcase)
      end

      def perform(method, path, headers, body, authorization)
        headers = headers.merge("Authorization" => authorization) if authorization
        raw_request(URI.parse("#{@configuration.url}#{path}"), method, headers, body)
      end

      def raw_request(uri, method, headers, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = @configuration.timeout
        klass = Net::HTTP.const_get(method.to_s.capitalize)
        req = klass.new(uri.request_uri, headers)
        req.body = body if body
        res = http.request(req)
        Response.new(status: res.code.to_i, headers: res.each_header.to_h { |k, v| [k.downcase, v] }, body: res.body.to_s)
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => e
        raise ProviderError, "registry request failed: #{e.class}"
      end
    end
  end
end
