module RuntimeImages
  module OciRegistry
    # Maps a namespace to exactly one registry repository:
    #
    #   <prefix>/<owner_kind>/<namespace name>
    #
    # owner_kind partitions classes of owner (platform bases, repository
    # devcontainers, coworker environments, ...) and the namespace name
    # partitions individual owners, so a credential or token scoped to one
    # repository can never reach another namespace's images.
    class RepositoryLayout
      def initialize(prefix:)
        @prefix = prefix
      end

      def repository_for(namespace)
        kind = namespace.owner_kind.to_s.downcase.tr("_", "-")
        unless kind.match?(Configuration::REPOSITORY_SEGMENT)
          raise ProviderError, "namespace owner kind #{namespace.owner_kind.inspect} cannot be mapped to a registry repository"
        end
        unless namespace.name.to_s.match?(RuntimeImageNamespace::NAME_FORMAT)
          raise ProviderError, "namespace name #{namespace.name.inspect} cannot be mapped to a registry repository"
        end
        [@prefix, kind, namespace.name].join("/")
      end

      def locator_for(namespace, host:, digest:)
        "#{host}/#{repository_for(namespace)}@#{digest}"
      end

      # True only when the locator names this namespace's own repository.
      def owns_locator?(namespace, locator, host:)
        locator.to_s.start_with?("#{host}/#{repository_for(namespace)}@")
      end
    end
  end
end
