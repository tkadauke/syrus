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

  # This provider could only give part of the answer -- GitHub truncates very
  # large trees and lists at most 300 changed files. An Unsupported, so the
  # chain asks the next provider and no caller mistakes it for the whole
  # answer. `partial` holds what it did return, for display callers that
  # would rather show a flagged partial list than an error:
  #
  #   entries = content.tree(revision)
  # rescue RepositoryContent::Truncated => e
  #   entries, truncated = e.partial, true
  class Truncated < Unsupported
    attr_reader :partial

    def initialize(message = nil, partial: [])
      super(message)
      @partial = partial
    end
  end

  # This provider does not know the ref or revision. Another may (a replica
  # that has not fetched it yet, say).
  class UnknownRevision < Error; end

  # The revision is known and the path is not in it. Final.
  class NotFound < Error; end

  FALL_THROUGH_ERRORS = [ Unavailable, Unsupported, UnknownRevision ].freeze

  DEFAULT_MAX_AGE = 60

  # Counts every read by who answered it. `provider` is a provider_key, or
  # "cache" for a cached answer and "none" when no provider serves the
  # repository; `kind` is the operation (resolve, tree, read, changes);
  # `outcome` is answered, not_found, unknown_revision, unsupported,
  # truncated, unavailable, or error. See Reader#record.
  def self.declare_metrics!
    Syrus::Metrics.declare do
      counter :repository_content_reads_total, tags: %i[provider kind outcome],
              comment: "Repository content reads by provider asked (or cache), operation, and outcome"
    end
  end
  declare_metrics!

  class << self
    # Test seam and escape hatch: when set, these provider classes are used
    # instead of the plugin registry's enabled providers.
    attr_accessor :provider_classes_override

    def for(repository, user: nil)
      Reader.new(repository: repository, user: user || repository.user)
    end

    def provider_classes
      classes = if provider_classes_override
        Array(provider_classes_override)
      else
        Syrus::PluginRegistry.providers_for(:repository_content_provider).map do |provider|
          provider.is_a?(String) ? provider.constantize : provider
        end
      end
      classes - excluded_provider_classes
    end

    # Answers everything inside the block as if `classes` were not installed.
    # The plugin disable guard uses it to ask "who would serve this
    # repository without this plugin?" -- which has to include providers
    # that only serve it with this plugin's help, like a mirror that needs
    # an upstream's credentials. Per thread, so other requests are unaffected.
    def without_providers(classes)
      previous = Thread.current[:repository_content_excluded]
      Thread.current[:repository_content_excluded] = Array(previous) + Array(classes)
      yield
    ensure
      Thread.current[:repository_content_excluded] = previous
    end

    def excluded_provider_classes
      Array(Thread.current[:repository_content_excluded])
    end

    # Where to fetch the repository from, asked of each upstream that serves
    # it in registry order: the first Source wins. nil when no upstream can
    # say (no credentials, or no upstream serves it). Replicas use this to
    # stay in sync; they never talk to a hosting platform directly.
    def upstream_source_for(repository, user: nil)
      provider_classes_for(repository).each do |klass|
        next unless klass.role == :upstream && klass.respond_to?(:upstream_source)

        source = klass.upstream_source(repository: repository, user: user || repository.user)
        return source if source
      rescue StandardError => e
        Rails.logger.warn("[RepositoryContent] #{klass.name} could not give an upstream source for #{repository.slug}: #{e.class}: #{e.message}")
      end
      nil
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
