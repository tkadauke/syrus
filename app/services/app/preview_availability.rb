module App
  # Shared "is a preview even possible for this repository" check, used by
  # RepositoryFeatureRecommendations' visual-review recommendation. Detects
  # either a registered `:preview_provider` plugin or a `.syrus.yml`
  # `preview:` block, read from the repository's default branch through
  # RepositoryContent (RepoDefaultBranchSyrusYml) rather than the local bare clone:
  # this is called from a repository-detail page load, which runs on the
  # web tier, and web pods don't mount the worker's on-disk bare clone (see
  # "Deploy target" in CLAUDE.md — "Web pods don't need this volume").
  # Mirrors the fix RepositoryFeatureRecommendations already applied for
  # its own local-bare-clone reads.
  class PreviewAvailability
    def self.configured?(repository, user: nil)
      Syrus::Plugin::PreviewProvider.configured? || syrus_yml_has_preview?(repository, user: user)
    end

    def self.syrus_yml_has_preview?(repository, user: nil)
      RepoDefaultBranchSyrusYml.new(repository: repository, user: user || repository.user).resolve.config&.preview.present?
    end
  end
end
