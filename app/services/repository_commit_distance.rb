require "fileutils"

# Coalesces and caches the "commits behind base" divergence used by
# merge-state polling.
#
# Without this, every tracked Job independently calls
# RepositoryBareClone#sync! (a full `git fetch --prune` of every branch)
# and #commits_behind during each PollAllMergeStatesJob fan-out tick --
# N Jobs sharing a repository means N redundant fetches and N redundant
# `git rev-list` calls per cycle, even though the answer is fully
# determined by the immutable (repository, base_sha, head_sha) tuple.
#
#   RepositoryCommitDistance.new(repository).commits_behind(
#     base_sha: pr.base.sha, head_sha: pr.head.sha, user: job.user
#   )
#
# Two coalescing layers:
#
# - The (repository, base_sha, head_sha) tuple is immutable once
#   computed, so its result is cached directly (a TTL bounds cache
#   growth, not correctness -- see DISTANCE_CACHE_TTL).
# - The underlying bare-clone refresh (a repo-wide `git fetch`) is
#   coalesced at repository scope: at most one refresh happens per
#   REFRESH_FRESHNESS_WINDOW, and a caller that lands inside another
#   caller's in-flight refresh blocks on a per-repository file lock
#   (shared across worker processes via $SYRUS_DATA_ROOT) instead of
#   racing a second fetch.
class RepositoryCommitDistance
  CACHE_NAMESPACE = "repository_commit_distance/v1".freeze
  DISTANCE_CACHE_TTL = 1.day
  # Slightly under PollAllMergeStatesJob's 5-minute cadence (see
  # config/recurring.yml) so a single bare-clone refresh coalesces the
  # base-revision resolution for an entire polling cycle's worth of Jobs
  # sharing a repository.
  REFRESH_FRESHNESS_WINDOW = 4.minutes

  # Counts every lookup by outcome: cache_hit (the distance for this
  # exact SHA tuple was already cached), cache_miss (it was not),
  # refreshed (this call performed the repo-scoped bare-clone fetch),
  # coalesced_wait (this call found another caller already refreshing
  # the same repository and waited for it instead of fetching itself).
  def self.declare_metrics!
    Syrus::Metrics.declare do
      counter :repository_commit_distance_lookups_total, tags: %i[outcome], cluster: true,
              comment: "Repository commit-distance lookups by outcome (cache_hit, cache_miss, refreshed, " \
                       "coalesced_wait), from every process (GLOBAL -- aggregate with max by, never sum)"
    end
  end
  declare_metrics!

  def initialize(repository, bare_clone: nil)
    @repository = repository
    @bare_clone = bare_clone || RepositoryBareClone.new(repository)
  end

  # Returns how many commits base_sha has that head_sha does not.
  # Returns nil if either SHA is blank, or if the bare clone cannot
  # answer (unreachable SHA, git error).
  def commits_behind(base_sha:, head_sha:, user:)
    return nil if base_sha.blank? || head_sha.blank?

    key = distance_cache_key(base_sha, head_sha)
    cached = Rails.cache.read(key)
    if cached
      record(:cache_hit)
      return cached
    end

    record(:cache_miss)
    ensure_fresh!(user: user)

    distance = @bare_clone.commits_behind(head_sha: head_sha, base_sha: base_sha)
    Rails.cache.write(key, distance, expires_in: DISTANCE_CACHE_TTL) unless distance.nil?
    distance
  end

  private

  def ensure_fresh!(user:)
    with_repository_lock do
      last_refreshed_at = Rails.cache.read(freshness_key)
      next if last_refreshed_at && last_refreshed_at >= REFRESH_FRESHNESS_WINDOW.ago

      record(:refreshed)
      @bare_clone.sync!(user: user)
      Rails.cache.write(freshness_key, Time.current, expires_in: REFRESH_FRESHNESS_WINDOW)
    end
  end

  # An exclusive, cross-process lock scoped to this repository's bare
  # clone path. A caller that has to wait here found another caller
  # already mid-refresh for the same repository -- that is exactly the
  # "duplicate full-ref fetch" this class exists to prevent.
  def with_repository_lock
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, File::CREAT | File::RDWR) do |lock_file|
      unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        record(:coalesced_wait)
        lock_file.flock(File::LOCK_EX)
      end
      yield
    ensure
      lock_file&.flock(File::LOCK_UN)
    end
  end

  def lock_path
    Pathname.new("#{RepositoryBareClone.path_for(@repository)}.refresh.lock")
  end

  def distance_cache_key(base_sha, head_sha)
    [ CACHE_NAMESPACE, "distance", @repository.id, base_sha, head_sha ].join("/")
  end

  def freshness_key
    [ CACHE_NAMESPACE, "refreshed_at", @repository.id ].join("/")
  end

  def record(outcome)
    Syrus::Metrics.counter(:syrus_repository_commit_distance_lookups_total)
      .increment(tags: { outcome: outcome.to_s })
  end
end
