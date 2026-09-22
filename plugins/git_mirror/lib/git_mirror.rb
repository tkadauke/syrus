module GitMirror
  extend Syrus::PluginApi

  syrus_plugin "git_mirror" do
    display_name "Git Mirror"
    description "Keeps local mirrors of your git repositories so Syrus reads them without asking the host."
    long_description "Git Mirror runs a small service that keeps a bare mirror of every active git repository, fetched in the background every 30 seconds. Syrus reads files, trees, and diffs from it first -- the .syrus.yml read before every workflow, preview projects, skills, the Job source browser -- and falls back to the hosting platform's API only when the mirror cannot answer.\n\nThat takes most of those reads off GitHub's rate limit and out of a network round trip. It costs disk space for the mirrors, which is why it is off by default and mostly worth it for larger installations. On Docker Compose, Plugin Runtime starts the service for you; on Kubernetes, deploy it yourself and point Syrus at it."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    depends_on [ "plugin_runtime" ]
    tick_interval 1.minute
    provides repository_content_provider: "GitMirror::ContentProvider",
             callbacks: "GitMirror::Callbacks",
             "plugin_runtime:service" => "GitMirror::RuntimeService"
  end
end
