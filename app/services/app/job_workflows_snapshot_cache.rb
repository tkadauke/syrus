module App
  # Caches the serialized Workflow -> Step -> Run tree of a Job's detail/
  # workflows payload by revision, instead of re-running the ~100-query
  # nested serialization (WorkflowSerializers#workflows_json) on every poll.
  #
  # The Job's own `entity_revision` only bumps when the Job row itself is
  # saved (see Revisionable), not when a child Workflow/Step/Run changes, so
  # it cannot key this cache on its own. Instead the fingerprint aggregates
  # the count and max `entity_revision` of every Workflow/Step/Run under the
  # Job -- three small indexed aggregate queries, cheap enough to run on every
  # request, that change if and only if the nested tree this method renders
  # would render differently. `admin` is folded in too: WorkflowSerializers
  # includes admin-only fields (failure classification inputs, diagnostic
  # internals) gated on @user.admin?, so a cached admin payload must never be
  # handed to a non-admin request or vice versa.
  class JobWorkflowsSnapshotCache
    CACHE_NAMESPACE = "job_workflows_snapshot/v1".freeze
    CACHE_TTL = 1.hour

    def self.declare_metrics!
      Syrus::Metrics.declare do
        # cluster: true so Metrics::AmplificationSampler (which runs on
        # whichever process SampleGlobalMetricsJob lands on -- a worker, not
        # necessarily the web process that actually served these requests)
        # can read an accurate cumulative total via Metrics::ClusterCounters
        # instead of an empty local registry.
        counter :detail_snapshot_requests_total, tags: %i[resource outcome], cluster: true,
                comment: "Requests for a cached detail snapshot (Job workflows tree, ...) by outcome " \
                         "(cache_hit, computed, coalesced), from every process (GLOBAL -- aggregate with max by, " \
                         "never sum) -- the cache-effectiveness and request-coalescing signal for EPIC-392"
      end
    end
    declare_metrics!

    def self.fetch(job:, page:, admin:, &block)
      new(job: job, page: page, admin: admin).fetch(&block)
    end

    def self.fingerprint(job:, page:, admin:)
      new(job: job, page: page, admin: admin).fingerprint
    end

    def initialize(job:, page:, admin:)
      @job = job
      @page = page
      @admin = admin
    end

    def fingerprint
      [ workflow_stats, step_stats, run_stats, @page, @admin ].join(":")
    end

    def fetch
      key = cache_key

      if (cached = Rails.cache.read(key))
        record(:cache_hit)
        return cached
      end

      result, coalesced = RequestCoalescer.call(key) { yield }
      record(coalesced ? :coalesced : :computed)
      Rails.cache.write(key, result, expires_in: CACHE_TTL) unless coalesced
      result
    end

    private

    def workflow_stats
      Workflow.where(job_id: @job.id).pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(entity_revision)"))
    end

    def step_stats
      Step.joins(:workflow).where(workflows: { job_id: @job.id }).pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(steps.entity_revision)"))
    end

    def run_stats
      Run.where(job_id: @job.id).pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(entity_revision)"))
    end

    def cache_key
      [ CACHE_NAMESPACE, @job.id, Digest::SHA256.hexdigest(fingerprint) ].join("/")
    end

    def record(outcome)
      Syrus::Metrics.counter(:syrus_detail_snapshot_requests_total)
        .increment(tags: { resource: "job_workflows", outcome: outcome.to_s })
    end
  end
end
