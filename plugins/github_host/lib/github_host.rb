module GithubHost
  extend Syrus::PluginApi

  syrus_plugin "github_host" do
    display_name "GitHub Host"
    description "Reads repository files, trees, and diffs from GitHub without cloning."
    long_description "GitHub Host lets Syrus look inside repositories hosted on GitHub without a checkout: reading .syrus.yml before a workflow is built, listing skills and preview projects, showing a Job's source. It answers through the GitHub API, so it works everywhere Syrus has GitHub credentials, at the cost of a network hop and GitHub's rate limits.\n\nA local mirror plugin, when enabled, answers first and falls back to this one. Issue ingestion and pull requests are GitHub Source's job, not this plugin's. It can be disabled only while no active GitHub repository would be left without another way to read its content."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/github_source.svg"
    author "Thomas Kadauke"
    category "connectivity"
    default_enabled true
    disableable true
    provides repository_content_provider: "GithubHost::ContentProvider"
  end
end
