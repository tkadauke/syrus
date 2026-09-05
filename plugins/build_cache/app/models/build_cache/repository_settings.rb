# Per-repository opt-in for sccache SCCACHE_BASEDIRS path normalization
# (EPIC-251 follow-up). Kept off the core Repository model deliberately --
# see Syrus::DataCleanup / PluginDataCleanup -- a plugin owns the rows that
# reference a core record's id, rather than the core model declaring an
# association back into a plugin table it could be deleted out from under.
#
# Absence of a row (the default for every repository) means "not opted in";
# see basedirs_safe_for? for the read side most callers should use instead
# of finding a row directly.
module BuildCache
  class RepositorySettings < ApplicationRecord
    self.table_name = "build_cache_repository_settings"

    belongs_to :repository

    validates :repository_id, uniqueness: true

    def self.for_repository(repository)
      find_by(repository_id: repository.is_a?(::Repository) ? repository.id : repository)
    end

    # A repository has proven (config/syrus_docs/sccache_build_cache.md's
    # "Cache-safe coverage recipe") that its coverage build's cached .gcno
    # notes are path-remapped/stable, so it's safe to normalize away the
    # ephemeral per-Workflow workspace path before hashing. Every other
    # repository keeps sccache's default exact-path-match behavior, which is
    # what keeps gcov/--coverage cache hits scoped to the same still-live
    # workspace. Missing row == false, the safe default.
    def self.basedirs_safe_for?(repository)
      for_repository(repository)&.basedirs_safe? || false
    end
  end
end
