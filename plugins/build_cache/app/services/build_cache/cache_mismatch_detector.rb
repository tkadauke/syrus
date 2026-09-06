# Flags the two silent sccache daemon-drift symptoms JOB-4309 surfaced:
# an operator-provisioned shared bucket whose captured stats still show a
# local-disk cache_location, and a repository opted into SCCACHE_BASEDIRS
# coverage-safe caching (BuildCache::RepositorySettings) whose captured
# stats show an empty basedirs list. Both mean the *daemon* serving compiler
# requests -- not just the command that just ran -- never picked up the
# config Syrus intended for it; see config/syrus_docs/sccache_build_cache.md
# and BuildCache::DaemonAddress for the per-Workflow daemon isolation this
# is a safety net for, not a replacement for.
#
# Best-effort and non-fatal: any failure here must never affect the
# workflow or the stats capture that already succeeded.
module BuildCache
  module CacheMismatchDetector
    WARNING_KIND = "sccache_config_mismatch"

    def self.check!(workflow:, step:, env:, stats:)
      summary = StatsSummary.for(stats)
      warn_local_disk_fallback!(workflow: workflow, step: step, env: env, summary: summary)
      warn_basedirs_not_applied!(workflow: workflow, step: step, env: env, stats: stats)
    rescue StandardError => e
      Rails.logger.error("[BuildCache::CacheMismatchDetector] #{e.class}: #{e.message}")
    end

    def self.warn_local_disk_fallback!(workflow:, step:, env:, summary:)
      return if env["SCCACHE_BUCKET"].to_s.empty?
      return unless summary.cache_location.to_s.match?(/local disk/i)

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: WARNING_KIND,
        severity: "medium",
        title: "sccache reports a local-disk cache despite SCCACHE_BUCKET being configured",
        evidence: { "cache_location" => summary.cache_location, "sccache_bucket" => env["SCCACHE_BUCKET"] },
        suggested_prompt: local_disk_prompt
      )
    end

    def self.warn_basedirs_not_applied!(workflow:, step:, env:, stats:)
      return if env["SCCACHE_BASEDIRS"].to_s.empty?
      return unless empty_basedirs?(stats)

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: WARNING_KIND,
        severity: "medium",
        title: "sccache basedirs configuration did not reach the compiler-serving daemon",
        evidence: { "expected_basedirs" => env["SCCACHE_BASEDIRS"] },
        suggested_prompt: basedirs_prompt
      )
    end

    def self.empty_basedirs?(stats)
      return false unless stats.is_a?(Hash)

      basedirs = stats["basedirs"]
      basedirs = stats.dig("stats", "basedirs") if basedirs.nil?
      basedirs.is_a?(Array) && basedirs.empty?
    end
    private_class_method :empty_basedirs?

    def self.local_disk_prompt
      "sccache reported a local-disk cache_location even though SCCACHE_BUCKET is configured for this repository. " \
        "This usually means the sccache daemon serving compiler requests was started (by an earlier command, or an " \
        "unrelated Workflow sharing this worker) before the shared-cache backend env was available, and never " \
        "restarted -- sccache only reads its backend config once, at server startup. Investigate whether the S3/MinIO " \
        "backend vars (SCCACHE_BUCKET/SCCACHE_ENDPOINT/SCCACHE_REGION/AWS credentials) are actually reaching the " \
        "worker pod, and whether daemon isolation (BuildCache::DaemonAddress) needs to widen its port span."
    end
    private_class_method :local_disk_prompt

    def self.basedirs_prompt
      "This repository is configured for cache-safe coverage caching (SCCACHE_BASEDIRS), but the sccache daemon's " \
        "captured stats reported an empty basedirs list -- meaning the daemon serving these compiles did not pick up " \
        "the setting. sccache only reads SCCACHE_BASEDIRS once, at server startup; investigate whether something else " \
        "started the daemon on this Workflow's derived port before prepare's env included it."
    end
    private_class_method :basedirs_prompt
  end
end
