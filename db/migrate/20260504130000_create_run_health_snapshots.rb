class CreateRunHealthSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :run_health_snapshots do |t|
      t.references :run, null: false, foreign_key: true

      # DB-level signals captured from the Run at snapshot time.
      t.string   :run_state,            null: false
      t.datetime :last_heartbeat_at
      t.integer  :heartbeat_age_seconds
      t.datetime :last_log_at
      t.integer  :log_count
      t.text     :last_log_preview     # first 200 chars of the most recent JobLog chunk
      t.integer  :agent_turns
      t.string   :agent_outcome
      t.integer  :agent_diff_bytes
      t.string   :head_sha

      # SolidQueue signals: state of the RunJob's SQ::Job.
      # claimed | ready | failed | finished | missing | nil (unavailable)
      t.string   :sq_job_state
      t.text     :sq_error_class        # FailedExecution.error["exception_class"]
      t.text     :sq_error_message      # FailedExecution.error["message"]
      t.text     :sq_error_backtrace    # first 10 frames

      # Process-level signals. nil = not checked / unavailable (no worktree,
      # not Linux, or an error reading /proc). false = checked and absent.
      t.boolean  :worktree_exists
      t.text     :worktree_git_status      # git status --porcelain output
      t.text     :worktree_recent_commits  # git log --oneline base..HEAD -5
      t.boolean  :claude_process_running
      t.text     :claude_process_info      # PID + cmdline excerpt when running
      t.boolean  :branch_on_origin         # local remote-tracking ref present?

      # MCP / sidecar. Always nil for now (sidecar uses stdio, not a socket).
      t.boolean  :mcp_sidecar_alive

      # Assessment rolled up from the signals above.
      t.string   :health_status   # healthy | warning | critical
      t.text     :hint            # one-sentence decision-helper for the operator

      t.timestamps
      t.index :created_at
    end
  end
end
