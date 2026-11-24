module RuntimeImages
  module OciRegistry
    # Operator-facing check of registry reachability and of each credential
    # role. Output never contains secrets. The probe repository only needs to
    # be a valid name; token services grant or deny scopes per credential.
    class Diagnostics
      Check = Data.define(:name, :status, :detail)

      def initialize(provider)
        @provider = provider
        @configuration = provider.configuration
      end

      def run(probe_repository: "#{@configuration.repository_prefix}/diagnostics/probe")
        client = HttpClient.new(@configuration)
        checks = [reachability(client), transport_check, separation_check]
        Configuration::ROLES.each { |role| checks << role_check(client, role, probe_repository) }
        checks.map { |c| c.with(detail: scrub(c.detail)) }
      end

      def ok?(checks) = checks.none? { |c| c.status == :fail }

      private

      def reachability(client)
        status = client.ping.status
        return Check.new("registry", :ok, "reachable (HTTP #{status})") if [200, 401].include?(status)
        Check.new("registry", :fail, "unexpected HTTP #{status} from /v2/")
      rescue RuntimeImages::Error => e
        Check.new("registry", :fail, e.message)
      end

      def transport_check
        return Check.new("transport", :ok, "https") if @configuration.secure?
        Check.new("transport", :warn, "registry url is not https; credentials travel unencrypted")
      end

      def separation_check
        roles = Configuration::ROLES.select { |r| @configuration.credential?(r) }
        secrets = roles.map { |r| @configuration.credential_for(r).secret_values }
        if roles.size == secrets.uniq.size
          Check.new("credential separation", :ok, "#{roles.size} distinct role credentials")
        else
          Check.new("credential separation", :warn, "roles share a credential; a worker compromise would grant push or delete")
        end
      end

      # A 200 from /v2/ only proves authentication, and a token's own claims
      # prove nothing about whether the registry accepts it. Every role is
      # therefore checked against the registry: a read-only tag listing must
      # be accepted (200, or a 404 that names the repository unknown, which
      # registries only answer after authorizing the token). A builder's push
      # right is verified by opening and cancelling a blob upload. Delete
      # cannot be probed without mutating, so it is reported from the token's
      # access claim when present and as unverified otherwise.
      def role_check(client, role, repository)
        name = "#{role} credential"
        return Check.new(name, :fail, "not configured") unless @configuration.credential?(role)
        actions = Configuration::ROLE_ACTIONS.fetch(role)
        token, = client.mint_token(role: role, repository: repository, actions: actions)
        reported = reported_actions(token, repository)
        if reported && (missing = actions - reported).any?
          return Check.new(name, :fail, "token service did not grant #{missing.join(',')}")
        end
        failure = pull_failure(client, role, repository, actions) || push_failure(client, role, repository, actions)
        return Check.new(name, :fail, failure) if failure
        verified_check(name, actions, reported)
      rescue RuntimeImages::Error => e
        Check.new("#{role} credential", :fail, e.message)
      end

      def verified_check(name, actions, reported)
        unverified = actions - %w[pull push]
        unverified -= reported.to_a
        return Check.new(name, :ok, "registry accepted #{(actions - unverified).join(',')}") if unverified.empty?
        Check.new(name, :warn, "registry accepted pull#{actions.include?('push') ? ',push' : ''}; #{unverified.join(',')} not verifiable without a scope-reporting token")
      end

      def pull_failure(client, role, repository, actions)
        response = client.request(role: role, repository: repository, method: :get,
                                  path: "/v2/#{repository}/tags/list", actions: actions)
        return nil if response.success?
        return nil if response.status == 404 && response.body.to_s.include?("NAME_UNKNOWN")
        "registry did not confirm pull access (HTTP #{response.status})"
      end

      def push_failure(client, role, repository, actions)
        return nil unless actions.include?("push")
        response = client.request(role: role, repository: repository, method: :post,
                                  path: "/v2/#{repository}/blobs/uploads/", actions: actions)
        return "registry denied push (HTTP #{response.status})" unless response.status == 202
        location = response.header("location").to_s
        cancel_upload(client, role, repository, actions, location)
        nil
      end

      def cancel_upload(client, role, repository, actions, location)
        target = URI.join("#{@configuration.url}/", location)
        path = target.request_uri
        return unless path.start_with?("/v2/#{repository}/blobs/uploads/")
        client.request(role: role, repository: repository, method: :delete, path: path, actions: actions)
      rescue RuntimeImages::Error, URI::InvalidURIError
        nil
      end

      def reported_actions(token, repository)
        payload = JSON.parse(Base64.urlsafe_decode64(token.to_s.split(".")[1].to_s.ljust((token.to_s.split(".")[1].to_s.length + 3) / 4 * 4, "=")))
        entries = Array(payload["access"]).select { |a| a["name"] == repository }
        entries.flat_map { |a| Array(a["actions"]) }.uniq
      rescue ArgumentError, JSON::ParserError, TypeError
        nil
      end

      def scrub(text)
        @configuration.secret_values.reduce(text.to_s) { |memo, secret| memo.gsub(secret, "[REDACTED]") }
      end
    end
  end
end
