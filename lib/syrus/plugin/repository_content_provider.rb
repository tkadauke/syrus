module Syrus
  module Plugin
    # Interface for `:repository_content_provider` extension points: plugins
    # that can answer "what does this repository contain at this revision?"
    # without a workspace checkout. Core reads through RepositoryContent, which
    # chains every enabled provider that applies to a repository; nothing in
    # core names a particular provider.
    #
    # The contract is VCS-neutral on purpose (git, Mercurial, Subversion):
    #
    #   - A *revision* is an opaque, immutable token whose format belongs to
    #     the VCS: a git commit SHA, a Mercurial changeset hash, a Subversion
    #     `branch@rev`. Anything read at a revision may be cached forever.
    #   - A *ref* is a movable name (branch, tag, bookmark) that `resolve`
    #     turns into a revision.
    #   - Paths are relative to the snapshot root, `/`-separated, no leading
    #     slash.
    #   - File content is bytes. RepositoryContent::Blob#text decodes.
    #
    # Two roles:
    #
    #   :upstream  the hosting platform itself (GitHub's API, later GitLab).
    #              Authoritative, but a network hop away and rate limited.
    #   :replica   a local copy kept in sync with an upstream (a mirror
    #              service). Tried first; falls through to upstreams when it
    #              cannot answer.
    #
    # Class methods (required):
    #
    #   provider_key                  -> String, stable identifier
    #   display_name                  -> String
    #   role                          -> :upstream or :replica
    #   available_for?(repository)    -> Boolean. Must be cheap and must not
    #                                    touch the network: the plugin disable
    #                                    guard calls it for every repository.
    #   build(repository:, user:)     -> a provider instance bound to that
    #                                    repository, or nil when it cannot serve
    #                                    it right now (e.g. no credentials).
    #
    # Class method (upstreams only, optional):
    #
    #   upstream_source(repository:, user:)
    #                                 -> RepositoryContent::Source, or nil. Where
    #                                    the repository lives and a credential to
    #                                    fetch it, so a replica can stay in sync
    #                                    without knowing anything about the host.
    #
    # Instance methods:
    #
    #   resolve(ref, max_age:)        -> RepositoryContent::Revision. `max_age`
    #                                    is seconds of staleness the caller will
    #                                    accept; 0 means ask the authority. A
    #                                    replica that cannot promise that raises
    #                                    Unavailable so the chain moves on.
    #   tree(revision_id)             -> Array<RepositoryContent::Entry>
    #   read(revision_id, path)       -> RepositoryContent::Blob
    #   changes(base_id, head_id, patch:)
    #                                 -> Array<RepositoryContent::Change> for
    #                                    what `head` introduced since its merge
    #                                    base with `base` (three-dot intent).
    #                                    Optional: the default raises
    #                                    Unsupported.
    #   refs(pattern:, max_age:)       -> Array<RepositoryContent::Ref>, in
    #                                    provider-defined newest-first order.
    #                                    Optional; patterns use File.fnmatch
    #                                    semantics.
    #   relation(base_id, head_id)     -> :identical, :ahead, :behind, or
    #                                    :diverged, describing head relative
    #                                    to base. Optional.
    #
    # Errors decide what the chain does next. Raise RepositoryContent::
    # Unavailable, Unsupported, or UnknownRevision to let the next provider
    # try; raise NotFound only when the revision is known and the path is
    # definitely not in it -- that answer is final. Any other exception is
    # treated as Unavailable.
    #
    # Register an implementation at boot time:
    #   provides repository_content_provider: "MyPlugin::ContentProvider"
    module RepositoryContentProvider
      ROLES = %i[replica upstream].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def provider_key
          raise NotImplementedError, "#{name} must implement .provider_key"
        end

        def display_name
          raise NotImplementedError, "#{name} must implement .display_name"
        end

        def role
          raise NotImplementedError, "#{name} must implement .role"
        end

        def available_for?(_repository)
          raise NotImplementedError, "#{name} must implement .available_for?"
        end

        def build(repository:, user:)
          raise NotImplementedError, "#{name} must implement .build"
        end
      end

      def resolve(_ref, max_age:)
        raise NotImplementedError, "#{self.class.name} must implement #resolve"
      end

      def tree(_revision_id)
        raise NotImplementedError, "#{self.class.name} must implement #tree"
      end

      def read(_revision_id, _path)
        raise NotImplementedError, "#{self.class.name} must implement #read"
      end

      def changes(_base_id, _head_id, patch: false)
        raise ::RepositoryContent::Unsupported, "#{self.class.display_name} does not compare revisions"
      end

      def refs(pattern:, max_age:)
        raise ::RepositoryContent::Unsupported, "#{self.class.display_name} does not list refs"
      end

      def relation(_base_id, _head_id)
        raise ::RepositoryContent::Unsupported, "#{self.class.display_name} does not compare revision ancestry"
      end
    end
  end
end
