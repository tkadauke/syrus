module RuntimeImages
  module BuildNetwork
    # One administrator-declarable kind of build destination. Each class owns
    # its own validation and matching, so callers never branch on the class
    # name: they ask the class registered for a rule's +source_class+.
    class SourceClass
      ECOSYSTEM = /\A[a-z0-9][a-z0-9_-]{0,31}\z/

      class << self
        def key = name.demodulize.underscore

        def registry
          @registry ||= [ OsMirror, LanguageRegistry, SourceHost, ArtifactRegistry, ExactDomain,
                          RepositoryNamespace, InternalMirror ].index_by(&:key).freeze
        end

        def for(key) = registry.fetch(key.to_s) { raise KeyError, "unknown build network source class #{key.inspect}" }.new
        def key?(key) = registry.key?(key.to_s)
        def keys = registry.keys
      end

      # Whether the class is required to name an ecosystem (npm, debian, ...).
      def ecosystem_required? = false
      def ecosystems = nil
      def path_scoped? = false
      # Only internal mirrors may resolve into private address space.
      def allow_private? = false
      # A required internal mirror displaces these classes for its ecosystem.
      def displaced_by_required_mirror? = false
      def requirable? = false

      # Returns error strings; empty when the rule is well-formed for the class.
      def validate(rule)
        errors = []
        errors << "ecosystem is required" if ecosystem_required? && rule.ecosystem.blank?
        if rule.ecosystem.present?
          errors << "ecosystem is invalid" unless rule.ecosystem.match?(ECOSYSTEM)
          errors << "ecosystem must be one of #{ecosystems.join(', ')}" if ecosystems && ecosystems.exclude?(rule.ecosystem)
        end
        errors << "path prefix is only valid for repository namespaces" if !path_scoped? && rule.path_prefix.present?
        errors << "required is only valid for internal mirrors" if rule.required && !requirable?
        errors
      end

      # +path+ is nil when the destination is a CONNECT tunnel, where the proxy
      # cannot see the request path.
      def matches?(rule, host:, port:, path:)
        rule.host == host && rule.port == port
      end

      class OsMirror < SourceClass
        def displaced_by_required_mirror? = true
      end

      class LanguageRegistry < SourceClass
        ECOSYSTEMS = %w[npm pypi rubygems cargo go maven nuget hex packagist].freeze
        # Well-known public registries. Used only to name a denial precisely
        # ("undeclared package registry"); they are never implicitly allowed.
        KNOWN_HOSTS = {
          "registry.npmjs.org" => "npm", "registry.yarnpkg.com" => "npm", "pypi.org" => "pypi",
          "files.pythonhosted.org" => "pypi", "rubygems.org" => "rubygems", "index.rubygems.org" => "rubygems",
          "crates.io" => "cargo", "static.crates.io" => "cargo", "index.crates.io" => "cargo",
          "proxy.golang.org" => "go", "sum.golang.org" => "go", "repo.maven.apache.org" => "maven",
          "repo1.maven.org" => "maven", "plugins.gradle.org" => "maven", "api.nuget.org" => "nuget",
          "repo.hex.pm" => "hex", "hex.pm" => "hex", "repo.packagist.org" => "packagist"
        }.freeze

        def ecosystem_required? = true
        def ecosystems = ECOSYSTEMS
        def displaced_by_required_mirror? = true
      end

      class SourceHost < SourceClass; end
      class ArtifactRegistry < SourceClass; end
      class ExactDomain < SourceClass; end

      # A path prefix on a host, e.g. github.com/acme/. Only enforceable where
      # the proxy can read the request path (plain HTTP); a CONNECT tunnel
      # hides it, so a namespace rule never admits a tunnel.
      class RepositoryNamespace < SourceClass
        def path_scoped? = true

        def validate(rule)
          errors = super
          prefix = rule.path_prefix.to_s
          errors << "path prefix is required" if prefix.blank?
          if prefix.present?
            errors << "path prefix must start and end with /" unless prefix.start_with?("/") && prefix.end_with?("/")
            errors << "path prefix may not contain traversal or encoded separators" if PathGuard.unsafe?(prefix)
          end
          errors
        end

        def matches?(rule, host:, port:, path:)
          return false unless super
          return false if path.nil? || PathGuard.unsafe?(path)

          path.start_with?(rule.path_prefix)
        end
      end

      class InternalMirror < SourceClass
        def allow_private? = true
        def requirable? = true
      end
    end

    module PathGuard
      UNSAFE = %r{(\A|/)\.\.?(/|\z)|%2e|%2f|%5c|//|\\|[\x00-\x1f]}i

      def self.unsafe?(path) = path.to_s.match?(UNSAFE)
    end
  end
end
