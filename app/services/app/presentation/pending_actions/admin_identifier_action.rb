module App
  module Presentation
    module PendingActions
      # Landing/admin repairs whose label is a fixed template filled in
      # from one or two payload identifier fields, with no detail line.
      class AdminIdentifierAction < Base
        TEMPLATES = {
          "admin_kill_process" => [ "Kill process #%s", %w[process_id] ],
          "admin_pause_user_scheduling" => [ "Pause scheduling for user #%s", %w[user_id] ],
          "admin_unpause_user_scheduling" => [ "Resume scheduling for user #%s", %w[user_id] ],
          "admin_retry_step" => [ "Retry step %s on workflow #%s", %w[step_slug workflow_id] ],
          "admin_cleanup_workspace" => [ "Delete workspace for workflow #%s", %w[workflow_id] ],
          "delegate_issue" => [ "Delegate issue #%s", %w[issue_number] ],
          "fire_scheduled_task_now" => [ "Fire scheduled task #%s", %w[scheduled_task_id] ],
          "restack_epic" => [ "Restack Epic #%s", %w[epic_id] ]
        }.freeze

        action_key(*TEMPLATES.keys)

        def label
          template, fields = TEMPLATES.fetch(key)
          format(template, *fields.map { |field| payload[field] })
        end
      end
    end
  end
end
