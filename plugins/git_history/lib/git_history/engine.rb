module GitHistory
  class Engine < ::Rails::Engine
    config.after_initialize do
      GitHistory.register!

      # Start the internal-only relay that serves bare-clone reads to web
      # pods (see GitHistory::RelayServer). Only ever runs on worker
      # processes — the same ones with the $SYRUS_DATA_ROOT PVC mounted —
      # never on web pods, and never in test (RelayClient specs start their
      # own instances against ephemeral ports). `ensure_running!` itself
      # further gates on WorkerQueueTopology so it only actually starts on
      # the worker pod(s) configured to consume the `polling` queue — the
      # only ones that ever sync a bare clone in the first place.
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
