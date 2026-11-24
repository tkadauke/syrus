module RuntimeImages
  module OciRegistry
    # Deployment configuration for the single configured registry. Each role
    # has its own credential so a leaked worker credential can never push or
    # delete:
    #
    #   builder - pull + push to one repository
    #   worker  - pull only
    #   admin   - pull + delete (control plane only)
    class Configuration
      ENV_PREFIX = "SYRUS_RUNTIME_IMAGE_REGISTRY_".freeze
      ROLES = %i[builder worker admin].freeze
      ROLE_ACTIONS = { builder: %w[pull push], worker: %w[pull], admin: %w[pull delete] }.freeze
      REPOSITORY_SEGMENT = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/

      class Invalid < RuntimeImages::Error; end

      attr_reader :url, :repository_prefix, :timeout

      def self.from_env(env = ENV)
        url = env["#{ENV_PREFIX}URL"].to_s.strip
        return nil if url.empty?
        credentials = ROLES.each_with_object({}) do |role, memo|
          name = role.to_s.upcase
          secret = env["#{ENV_PREFIX}#{name}_PASSWORD"].to_s
          next if secret.empty?
          memo[role] = Credential.new(username: env["#{ENV_PREFIX}#{name}_USERNAME"], secret: secret)
        end
        new(url: url, repository_prefix: env.fetch("#{ENV_PREFIX}REPOSITORY_PREFIX", "syrus"),
            credentials: credentials, timeout: env.fetch("#{ENV_PREFIX}TIMEOUT", 30))
      end

      # Names of every environment variable that carries deployment registry
      # configuration or credentials. Workloads must never see these.
      def self.env_names
        ROLES.flat_map { |r| ["#{ENV_PREFIX}#{r.to_s.upcase}_USERNAME", "#{ENV_PREFIX}#{r.to_s.upcase}_PASSWORD"] } +
          ["#{ENV_PREFIX}URL", "#{ENV_PREFIX}REPOSITORY_PREFIX", "#{ENV_PREFIX}TIMEOUT"]
      end

      def initialize(url:, credentials:, repository_prefix: "syrus", timeout: 30)
        @url = url.to_s.chomp("/")
        @repository_prefix = repository_prefix.to_s
        @credentials = credentials.freeze
        @timeout = Float(timeout)
        validate!
      end

      def credential_for(role)
        @credentials.fetch(role.to_sym) { raise Invalid, "no #{role} credential configured for the runtime image registry" }
      end

      def credential?(role) = @credentials.key?(role.to_sym)
      def host = URI.parse(url).then { |u| u.port == u.default_port ? u.host : "#{u.host}:#{u.port}" }
      def secret_values = @credentials.values.flat_map(&:secret_values)
      def secure? = URI.parse(url).scheme == "https"

      def inspect = "#<#{self.class.name} url=#{url.inspect} roles=#{@credentials.keys.inspect}>"
      alias_method :to_s, :inspect

      private

      def validate!
        uri = URI.parse(@url)
        raise Invalid, "registry url must be http(s)" unless uri.is_a?(URI::HTTP) && uri.host.present?
        raise Invalid, "registry url must not embed credentials" if uri.userinfo
        @repository_prefix.split("/").each do |segment|
          raise Invalid, "invalid repository prefix #{@repository_prefix.inspect}" unless segment.match?(REPOSITORY_SEGMENT)
        end
        raise Invalid, "repository prefix is required" if @repository_prefix.empty?
      rescue URI::InvalidURIError
        raise Invalid, "registry url is not a valid URL"
      end
    end
  end
end
