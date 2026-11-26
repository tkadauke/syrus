# Resolves the optional coverage plan configured in `.syrus.yml`.
#
# Thin adapter over RepoDefaultBranchSyrusYml, which owns the actual GitHub
# fetch and SyrusYml parse (shared with the review and grade plans so
# Workflows::Base resolves the repository's default-branch config once per
# workflow instantiation instead of each plan fetching it independently).
# The coverage block is a plugin-owned repository configuration, so a
# malformed block is reported by the same parser as every other `.syrus.yml`
# key, and a repository's own block is simply absent while this plugin is
# disabled.
class SyrusCoverage::PlanReader
  def self.for_job(job)
    from_syrus_yml(Syrus::Host::RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    loaded.config&.plugin_configurations&.[](SyrusCoverage::RepositoryConfiguration::KEY)
  end
end
