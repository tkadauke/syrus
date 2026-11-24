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

      def role_check(client, role, repository)
        return Check.new("#{role} credential", :fail, "not configured") unless @configuration.credential?(role)
        actions = Configuration::ROLE_ACTIONS.fetch(role)
        granted = client.request(role: role, repository: repository, method: :get, path: "/v2/", actions: actions)
        return Check.new("#{role} credential", :ok, "authenticated for #{actions.join(',')}") if granted.success?
        Check.new("#{role} credential", :fail, "registry answered HTTP #{granted.status}")
      rescue RuntimeImages::Error => e
        Check.new("#{role} credential", :fail, e.message)
      end

      def scrub(text)
        @configuration.secret_values.reduce(text.to_s) { |memo, secret| memo.gsub(secret, "[REDACTED]") }
      end
    end
  end
end
