module App
  module Presentation
    module PendingActions
      # Simple static labels: no payload substitution, no detail line.
      class StaticLabelAction < Base
        LABELS = {
          "admin_reap_stale_runs" => "Force-reap stale runs",
          "admin_pause_polling" => "Pause repository polling",
          "admin_unpause_polling" => "Resume repository polling",
          "admin_pause_runs" => "Pause runs",
          "admin_unpause_runs" => "Resume runs",
          "admin_clear_github_cache" => "Clear GitHub API cache",
          "admin_refresh_installations" => "Refresh GitHub App installations",
          "wake_landing_queue" => "Wake landing queue",
          "pause_landing_queue" => "Pause landing queue",
          "resume_landing_queue" => "Resume landing queue"
        }.freeze

        action_key(*LABELS.keys)

        def label
          LABELS.fetch(key)
        end
      end
    end
  end
end
