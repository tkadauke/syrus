require "git_history/version"
require "git_history/engine"

module GitHistory
  def self.register!
    GitHistory::RepoPageTabs.include(Syrus::Plugin::RepoPageTab) unless GitHistory::RepoPageTabs < Syrus::Plugin::RepoPageTab

    Syrus::PluginRegistry.register(
      name:            "git_history",
      display_name:    "Git History",
      version:         GitHistory::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "observability",
      description:     "Full commit history for a repository, with attribution back to the Syrus Job/Epic/chat/issue/cron task that landed it.",
      homepage:        "https://github.com/tkadauke/syrus",
      author:          "Thomas Kadauke",
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/repositories/:repository_id/git_history/commits",
          controller: "api/v1/app/git_history#index"
        }
      ],
      provides: {
        repo_page_tab: GitHistory::RepoPageTabs
      }
    )
  end
end
