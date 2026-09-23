module RepositoryContent
  # The chain of providers for one repository. Built by RepositoryContent.for.
  #
  # Every read takes a Revision (from #resolve, or #revision for an id the
  # caller already knows is immutable) rather than a ref string, so the cache
  # can never mistake a moving branch name for a fixed point in history.
  class Reader
    CACHE_NAMESPACE = "repository_content/v1".freeze
    RESOLVE_CACHE_TTL = 1.hour
    CONTENT_CACHE_TTL = 1.day
    # Blobs above this are read through but not cached; the cache is for the
    # config files and manifests callers read over and over.
    MAX_CACHED_BLOB_BYTES = 256.kilobytes
    # Trees above this are read through but not cached.
    MAX_CACHED_TREE_ENTRIES = 20_000
    DEFAULT_MAX_FILES = 200

    # Metric label values for answers that did not come from a provider.
    CACHE_PROVIDER = "cache".freeze
    NO_PROVIDER = "none".freeze
    OUTCOME_FOR = {
      Unavailable => "unavailable",
      NoProvider => "unavailable",
      Unsupported => "unsupported",
      UnknownRevision => "unknown_revision"
    }.freeze

    attr_reader :repository, :user

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    # Turns a ref into a Revision. A resolution younger than `max_age`
    # seconds is reused; `max_age: 0` always asks the chain.
    def resolve(ref, max_age: DEFAULT_MAX_AGE)
      raise ArgumentError, "ref is required" if ref.blank?

      key = cache_key("resolve", ref)
      if max_age.to_i.positive? && (cached = cache.read(key))
        observed_at = Time.zone.parse(cached["observed_at"])
        if observed_at >= max_age.to_i.seconds.ago
          record(CACHE_PROVIDER, :resolve, "answered")
          return Revision.new(id: cached["id"], ref: ref, observed_at: observed_at)
        end
      end

      revision = through_chain(:resolve) { |provider| provider.resolve(ref, max_age: max_age.to_i) }
      revision = Revision.new(id: revision.id, ref: ref, observed_at: revision.observed_at || Time.current)
      cache.write(key, { "id" => revision.id, "observed_at" => revision.observed_at.iso8601(6) }, expires_in: RESOLVE_CACHE_TTL)
      revision
    end

    # Wraps a revision id the caller already holds (a commit SHA recorded on
    # a Run, say). Only for ids that came from the VCS -- never a branch name.
    def revision(id)
      id.is_a?(Revision) ? id : Revision.new(id: id)
    end

    # Every path in the revision, optionally narrowed by RepositoryContent::Glob
    # patterns.
    def tree(revision, glob: nil)
      id = revision_id(revision)
      key = cache_key("tree", id)
      entries = cache.read(key)&.map { |attrs| Entry.new(**attrs.symbolize_keys) }
      record(CACHE_PROVIDER, :tree, "answered") if entries
      unless entries
        entries = through_chain(:tree) { |provider| provider.tree(id) }
        if entries.size <= MAX_CACHED_TREE_ENTRIES
          cache.write(key, entries.map { |entry| entry.to_h.transform_keys(&:to_s) }, expires_in: CONTENT_CACHE_TTL)
        end
      end
      Glob.filter(glob, entries)
    end

    # The file at `path`. Raises NotFound when the revision has no such file.
    # `max_bytes` bounds what the caller receives; `size` still reports the
    # whole file.
    def read(revision, path, max_bytes: nil)
      id = revision_id(revision)
      path = normalize_path(path)
      key = cache_key("blob", id, path)

      blob = cached_blob(key, path) || begin
        fetched = through_chain(:read) { |provider| provider.read(id, path) }
        cache_blob(key, fetched)
        fetched
      rescue NotFound
        cache.write(key, { "missing" => true }, expires_in: CONTENT_CACHE_TTL)
        raise
      end

      truncate(blob, max_bytes)
    end

    # The file at `path`, or nil when the revision has no such file. Outages
    # still raise Unavailable -- only a confirmed absence becomes nil.
    def read_if_present(revision, path, max_bytes: nil)
      read(revision, path, max_bytes: max_bytes)
    rescue NotFound
      nil
    end

    # Every file matching `glob`, as { path => Blob }. Bounded by `max_files`
    # so a careless pattern cannot fan out into thousands of reads; raises
    # ArgumentError past it.
    def files(revision, glob:, max_files: DEFAULT_MAX_FILES, max_bytes: nil)
      entries = tree(revision, glob: glob).select(&:file?)
      if entries.size > max_files
        raise ArgumentError, "#{entries.size} files match #{glob.inspect}; more than max_files (#{max_files})"
      end

      entries.to_h { |entry| [ entry.path, read(revision, entry.path, max_bytes: max_bytes) ] }
    end

    # What `head` introduced since its merge base with `base` -- GitHub's
    # "Files changed" view, `git diff base...head`.
    def changes(base:, head:, patch: false)
      base_id = revision_id(base)
      head_id = revision_id(head)
      key = cache_key("changes", base_id, head_id, patch ? "patch" : "names")
      cached = cache.read(key)
      if cached
        record(CACHE_PROVIDER, :changes, "answered")
        return cached.map { |attrs| Change.new(**attrs.symbolize_keys) }
      end

      result = through_chain(:changes) { |provider| provider.changes(base_id, head_id, patch: patch) }
      cache.write(key, result.map { |change| change.to_h.transform_keys(&:to_s) }, expires_in: CONTENT_CACHE_TTL)
      result
    end

    # Movable refs matching `pattern`, in provider-defined newest-first order.
    def refs(pattern:, max_age: DEFAULT_MAX_AGE)
      raise ArgumentError, "pattern is required" if pattern.blank?

      through_chain(:refs) { |provider| provider.refs(pattern: pattern, max_age: max_age.to_i) }
    end

    # Describes head relative to base: identical, ahead, behind, or diverged.
    def relation(base:, head:)
      base_id = revision_id(base)
      head_id = revision_id(head)
      through_chain(:relation) { |provider| provider.relation(base_id, head_id) }.to_sym
    end

    # Head relative to base as numeric commit counts (GitHub compare's
    # ahead_by/behind_by).
    def divergence(base:, head:)
      base_id = revision_id(base)
      head_id = revision_id(head)
      through_chain(:divergence) { |provider| provider.divergence(base_id, head_id) }
    end

    # The provider instances that will be asked, in order. Exposed for
    # diagnostics.
    def providers
      @providers ||= RepositoryContent.provider_classes_for(repository).filter_map do |klass|
        klass.build(repository: repository, user: user)
      rescue StandardError => e
        Rails.logger.warn("[RepositoryContent] #{klass.name} could not be built for #{repository.slug}: #{e.class}: #{e.message}")
        nil
      end
    end

    private

    def through_chain(operation)
      chain = providers
      if chain.empty?
        message = "no repository content provider serves #{repository.slug}"
        Rails.logger.error("[RepositoryContent] #{message}")
        record(NO_PROVIDER, operation, "unavailable")
        raise NoProvider, message
      end

      last_error = nil
      truncated = nil
      chain.each do |provider|
        key = metric_label(provider)
        begin
          result = yield(provider)
          record(key, operation, "answered")
          return result
        rescue NotFound
          record(key, operation, "not_found")
          raise
        rescue *FALL_THROUGH_ERRORS => e
          record(key, operation, e.is_a?(Truncated) ? "truncated" : OUTCOME_FOR.fetch(e.class, "unavailable"))
          truncated ||= e if e.is_a?(Truncated)
          last_error = e
        rescue StandardError => e
          record(key, operation, "error")
          Rails.logger.warn("[RepositoryContent] #{provider.class.name}##{operation} failed for #{repository.slug}: #{e.class}: #{e.message}")
          last_error = Unavailable.new("#{provider.class.display_name}: #{e.class}: #{e.message}")
        end
      end
      # A partial answer is more use than "unavailable" to a caller that can
      # show one, and no less of a failure to one that cannot.
      raise truncated || last_error
    end

    def cached_blob(key, path)
      cached = cache.read(key)
      return unless cached

      record(CACHE_PROVIDER, :read, cached["missing"] ? "not_found" : "answered")
      raise NotFound, "#{path} not found" if cached["missing"]

      Blob.new(path: path, bytes: cached["bytes"].unpack1("m0"), size: cached["size"], content_id: cached["content_id"])
    end

    def cache_blob(key, blob)
      return if blob.truncated || blob.bytes.bytesize > MAX_CACHED_BLOB_BYTES

      cache.write(key, { "bytes" => [ blob.bytes ].pack("m0"), "size" => blob.size, "content_id" => blob.content_id }, expires_in: CONTENT_CACHE_TTL)
    end

    def truncate(blob, max_bytes)
      return blob if max_bytes.nil? || blob.bytes.bytesize <= max_bytes

      # `bytes` is always binary (Blob forces ASCII-8BIT), where String#[]
      # counts bytes. safe_byteslice would transcode to UTF-8 and corrupt
      # binary content; Blob#text is where decoding happens.
      blob.with(bytes: blob.bytes[0, max_bytes], truncated: true)
    end

    def revision_id(revision)
      unless revision.is_a?(Revision)
        raise ArgumentError, "expected a RepositoryContent::Revision (use #resolve for refs or #revision for known ids), got #{revision.inspect}"
      end

      revision.id
    end

    def normalize_path(path)
      path.to_s.delete_prefix("/").tap { |normalized| raise ArgumentError, "path is required" if normalized.empty? }
    end

    # One count per provider asked and per cache hit, so "who answered?" is a
    # query rather than an inference: a read the mirror answered shows as
    # provider="git_mirror" outcome="answered"; one it could not, as its
    # fall-through outcome followed by the upstream's answer.
    # A provider's key names it on the counter. Counting must never be what
    # fails a read, so one without a key (a test double, a half-written
    # plugin) is labelled by class instead.
    def metric_label(provider)
      klass = provider.class
      klass.respond_to?(:provider_key) ? klass.provider_key : klass.name.to_s.demodulize.underscore.presence || "unknown"
    end

    def record(provider, operation, outcome)
      Syrus::Metrics.counter(:syrus_repository_content_reads_total)
        .increment(tags: { provider: provider.to_s, kind: operation.to_s, outcome: outcome })
    end

    def cache_key(*parts)
      [ CACHE_NAMESPACE, repository.id, *parts.map { |part| Digest::SHA256.hexdigest(part.to_s)[0, 32] } ].join("/")
    end

    def cache
      Rails.cache
    end
  end
end
