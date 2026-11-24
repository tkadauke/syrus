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

      # A 200 from /v2/ only proves authentication, not scope. Prefer the
      # access claim the token service reports for the probe repository; when
      # the token is opaque, verify pull with a read-only tag listing and
      # report push/delete as unverified instead of claiming them.
      def role_check(client, role, repository)
        name = "#{role} credential"
        return Check.new(name, :fail, "not configured") unless @configuration.credential?(role)
        actions = Configuration::ROLE_ACTIONS.fetch(role)
        token, = client.mint_token(role: role, repository: repository, actions: actions)
        reported = reported_actions(token, repository)
        return claim_check(name, actions, reported) if reported
        probe_check(client, role, repository, actions, name)
      rescue RuntimeImages::Error => e
        Check.new("#{role} credential", :fail, e.message)
      end

      def claim_check(name, actions, reported)
        missing = actions - reported
        return Check.new(name, :ok, "token grants #{actions.join(',')}") if missing.empty?
        Check.new(name, :fail, "token service did not grant #{missing.join(',')}")
      end

      def probe_check(client, role, repository, actions, name)
        response = client.request(role: role, repository: repository, method: :get,
                                  path: "/v2/#{repository}/tags/list", actions: actions)
        unless response.success? || response.status == 404
          return Check.new(name, :fail, "registry denied pull (HTTP #{response.status})")
        end
        unverified = actions - ["pull"]
        return Check.new(name, :ok, "authenticated for pull") if unverified.empty?
        Check.new(name, :warn, "pull verified; #{unverified.join(',')} not verifiable without a scope-reporting token")
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
