module GitMirror
  extend Syrus::PluginApi

  syrus_plugin "git_mirror" do
    display_name "Git Mirror"
    description "Keeps local mirrors of your git repositories so Syrus reads them without asking the host."
    long_description "Git Mirror runs a small service that keeps a bare mirror of every active git repository, fetched in the background every 30 seconds. Syrus reads files, trees, and diffs from it first -- the .syrus.yml read before every workflow, preview projects, skills, the Job source browser -- and falls back to the hosting platform's API only when the mirror cannot answer.\n\nThat takes most of those reads off GitHub's rate limit and out of a network round trip. It costs disk space for the mirrors, which is why it is off by default and mostly worth it for larger installations. On Docker Compose, Plugin Runtime starts the service for you; on Kubernetes, deploy it yourself and point Syrus at it."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/git_mirror.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    depends_on [ "plugin_runtime" ]
    tick_interval 1.minute
    metrics do
      gauge :repositories, comment: "Repositories the git mirror holds" do
        GitMirror::Stats.repository_count
      end
      gauge :mirror_bytes, comment: "Bytes the git mirrors take up on the mirror's volume" do
        GitMirror::Stats.disk("mirror_bytes")
      end
      gauge :disk_free_bytes, comment: "Free bytes on the git mirror's data volume" do
        GitMirror::Stats.disk("free_bytes")
      end
      gauge :disk_total_bytes, comment: "Size of the git mirror's data volume in bytes" do
        GitMirror::Stats.disk("total_bytes")
      end
    end
    frontend i18n: [ "app/frontend/i18n/locales/*/git_mirror.json" ]
    provides repository_content_provider: "GitMirror::ContentProvider",
             workspace_git_transport: "GitMirror::WorkspaceGitTransport",
             callbacks: "GitMirror::Callbacks",
             "plugin_runtime:service" => "GitMirror::RuntimeService"
  end
end
