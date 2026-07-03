class EnlargeLargeTextColumnsToMediumtext < ActiveRecord::Migration[8.1]
  # Audit of TEXT columns triggered by the runs.prompt overflow in prod
  # (Mysql2::Error: Data too long for column 'prompt' at row 1) after
  # the pr_comment prompt started including full conversation history
  # + prior summaries + recent commits.
  #
  # MySQL TEXT caps at 65 KB; MEDIUMTEXT caps at 16 MB. Promote
  # columns that can realistically grow past 65 KB given how Syrus
  # actually fills them.
  #
  # Promoted (HIGH risk):
  #   - jobs.issue_body         — GitHub issues run to 100+ KB
  #   - chat_proposals.body     — same content, pre-file
  #   - runs.agent_pr_body      — agent-authored PR body + cost footer
  #   - scheduled_tasks.prompt  — operator-authored, no enforced bound
  #   - cron_templates.prompt   — same
  #
  # Promoted (MEDIUM risk, defensive):
  #   - run_diagnostics.error_backtrace
  #   - run_diagnostics.environment_snapshot
  #   - run_diagnostics.git_snapshot
  #   - run_diagnostics.repo_snapshot
  #
  # Left as plain TEXT (genuinely small):
  #   - runs.agent_summary             (1-2 sentences per prompt contract)
  #   - runs.operator_chat_response    (chat-bounded)
  #   - jobs.invalidation_reason       (free text but short)
  #   - jobs.landing_failure_reason    (truncated to 500 by RunJob)
  #   - repository_notes.body          (operator-authored notes, short)
  #   - run_health_snapshots.*         (bounded probe outputs)
  #   - scheduled_tasks.description    (one-line label)
  #   - cron_templates.description     (one-line label)
  #   - run_diagnostics.error_message  (one-line error)
  #
  # SQLite ignores the limit (TEXT has no upper bound there), so
  # dev/test sees no schema change.
  PROMOTIONS = [
    %i[ jobs issue_body ],
    %i[ chat_proposals body ],
    %i[ runs agent_pr_body ],
    %i[ scheduled_tasks prompt ],
    %i[ cron_templates prompt ],
    %i[ run_diagnostics error_backtrace ],
    %i[ run_diagnostics environment_snapshot ],
    %i[ run_diagnostics git_snapshot ],
    %i[ run_diagnostics repo_snapshot ]
  ].freeze

  def up
    return unless mysql?

    PROMOTIONS.each do |table, column|
      next unless column_exists?(table, column)
      change_column table, column, :text, limit: 16.megabytes
    end
  end

  def down
    return unless mysql?

    PROMOTIONS.each do |table, column|
      next unless column_exists?(table, column)
      change_column table, column, :text
    end
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
