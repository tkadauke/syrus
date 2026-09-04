module GitHistory
  extend Syrus::PluginApi

  syrus_plugin "git_history" do
    display_name "Git History"
    description "Full commit history for a repository, with attribution back to the Syrus Job/Epic/chat/issue/cron task that landed it."
    long_description "Git History adds a repository tab that traces commits back to the Syrus work that produced them. It connects Git commits to jobs, epics, chats, issues, cron tasks, and landing activity so operators can answer why a commit exists and which automation path created it.\n\nThis plugin is useful for auditability and debugging confusing branch history. It reads local bare clones maintained by Syrus and presents the history in the app without changing repository behavior."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/git_history.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled true
    disableable true
    provides repo_page_tab: "GitHistory::RepoPageTabs"
    route :get, "/api/v1/app/repositories/:repository_id/git_history/commits", to: "api/v1/app/git_history#index"

    # Start the internal-only relay that serves bare-clone reads to web pods
    # (see GitHistory::RelayServer). Only ever runs on worker processes -- the
    # same ones with the $SYRUS_DATA_ROOT PVC mounted -- never on web pods, and
    # never in test (RelayClient specs start their own instances against
    # ephemeral ports). `ensure_running!` itself further gates on
    # WorkerQueueTopology so it only actually starts on the worker pod(s)
    # configured to consume the `polling` queue.
    on_boot do
      if SyrusVersion.server_process? && SyrusVersion.role == "worker"
        begin
          GitHistory::RelayServer.ensure_running!
        rescue NameError
          # Zeitwerk autoloads not yet re-registered in this reload cycle;
          # the relay is already running from the previous cycle.
        end
      end
    end
  end
end
