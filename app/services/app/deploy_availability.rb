module App
  # Shared "is a manual deploy even possible for this repository" check,
  # used by JobDetailPayload's can_deploy action flag, JobDeployController's
  # approval gate, and DeployContinuousTrigger's continuous-deploy check.
  # Reads `.syrus.yml`'s `deploy:` block from the repository's default
  # branch through GitHub (RepoDefaultBranchSyrusYml) rather than shelling
  # out against the local bare clone: several of these call sites run on the
  # web tier, and web pods don't mount $SYRUS_DATA_ROOT (see "Deploy target"
  # in CLAUDE.md — "Web pods don't need this volume"). A local bare clone
  # never existing there made `File.directory?(clone_path)` always false, so
  # `allow_unapproved?` always answered `false` regardless of what
  # `.syrus.yml` actually configured. Mirrors the fix
  # RepositoryFeatureRecommendations already applied for its own
  # local-bare-clone reads.
  class DeployAvailability
    def self.configured?(repository, user: nil, client: nil)
      deploy_config(repository, user: user, client: client).present?
    end

    def self.allow_unapproved?(repository, user: nil, client: nil)
      deploy_config(repository, user: user, client: client)&.allow_unapproved || false
    end

    def self.deploy_config(repository, user: nil, client: nil)
      RepoDefaultBranchSyrusYml.new(repository: repository, user: user || repository.user, client: client).resolve.config&.deploy
    end
  end
end
