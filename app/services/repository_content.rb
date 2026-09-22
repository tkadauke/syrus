# Read what a repository contains at a revision -- files, the tree, what
# changed between two revisions -- without cloning it.
#
#   content  = RepositoryContent.for(repository, user: user)
#   revision = content.resolve(repository.default_branch)
#   blob     = content.read(revision, ".syrus.yml")
#   blob.text
#
# Answers come from the `repository_content_provider` plugins that apply to
# the repository, replicas first and upstreams after (see
# Syrus::Plugin::RepositoryContentProvider for the provider contract and the
# meaning of revisions, refs, and roles). Core never names a provider.
#
# Reads at a revision are immutable, so this caches them: trees, small blobs,
# and confirmed absences. Resolving a ref is cached for `max_age` seconds.
#
# Callers must handle two kinds of failure differently:
#
#   NotFound     the path is definitely not in that revision -- a real answer.
#   Unavailable  nobody could find out (rate limit, outage, no credentials,
#                no provider). Never treat this as "absent".
module RepositoryContent
  class Error < StandardError; end

  # Nobody could answer right now. The chain moves on to the next provider.
  class Unavailable < Error; end

  # No enabled provider applies to this repository. An Unavailable, so callers
  # that already handle outages stay safe, but logged loudly: it means an
  # installation is misconfigured, not that GitHub is having a bad day.
  class NoProvider < Unavailable; end

  # This provider cannot do that operation (or not for this repository/VCS).
  class Unsupported < Error; end

  # This provider does not know the ref or revision. Another may (a replica
  # that has not fetched it yet, say).
  class UnknownRevision < Error; end

  # The revision is known and the path is not in it. Final.
  class NotFound < Error; end

  FALL_THROUGH_ERRORS = [ Unavailable, Unsupported, UnknownRevision ].freeze

  DEFAULT_MAX_AGE = 60

  class << self
    # Test seam and escape hatch: when set, these provider classes are used
    # instead of the plugin registry's enabled providers.
    attr_accessor :provider_classes_override

    def for(repository, user: nil)
      Reader.new(repository: repository, user: user || repository.user)
    end

    def provider_classes
      return Array(provider_classes_override) if provider_classes_override

      Syrus::PluginRegistry.providers_for(:repository_content_provider).map do |provider|
        provider.is_a?(String) ? provider.constantize : provider
      end
    end

    # Providers that claim the repository, replicas before upstreams, in
    # registry order within a role.
    def provider_classes_for(repository)
      provider_classes
        .select { |klass| klass.available_for?(repository) }
        .sort_by.with_index { |klass, index| [ klass.role == :replica ? 0 : 1, index ] }
    end
  end
end
