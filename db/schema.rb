# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_04_130000) do
  create_table "admin_actions", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.text "params"
    t.datetime "performed_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["performed_at"], name: "index_admin_actions_on_performed_at"
    t.index ["user_id"], name: "index_admin_actions_on_user_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "max_job_failures", default: 3, null: false
    t.boolean "polling_paused", default: false, null: false
    t.boolean "runs_paused", default: false, null: false
    t.boolean "signups_open", default: false, null: false
    t.datetime "updated_at", null: false
  end

  create_table "claude_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "run_id", null: false
    t.string "session_id", null: false
    t.text "transcript_jsonl", limit: 67108864
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_claude_sessions_on_created_at"
    t.index ["run_id"], name: "index_claude_sessions_on_run_id", unique: true
  end

  create_table "cron_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cron_expression", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.string "name", null: false
    t.string "pr_pileup_policy", default: "skip", null: false
    t.text "prompt", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_cron_templates_on_user_id"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "expires_at", null: false
    t.integer "invited_by_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_invitations_on_email_address"
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "job_logs", force: :cascade do |t|
    t.text "chunk", null: false
    t.datetime "created_at", null: false
    t.string "kind"
    t.integer "run_id", null: false
    t.integer "sequence", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "sequence"], name: "index_job_logs_on_run_id_and_sequence", unique: true
    t.index ["run_id"], name: "index_job_logs_on_run_id"
  end

  create_table "jobs", force: :cascade do |t|
    t.string "branch_name"
    t.string "closure_reason"
    t.datetime "created_at", null: false
    t.integer "external_pr_number"
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.text "issue_body"
    t.integer "issue_number"
    t.string "issue_title"
    t.string "kind", default: "issue", null: false
    t.string "last_ci_handled_sha"
    t.datetime "last_seen_comment_at"
    t.boolean "pr_mergeable"
    t.datetime "pr_mergeable_checked_at"
    t.integer "pr_number"
    t.integer "repository_id", null: false
    t.integer "scheduled_task_id"
    t.datetime "started_at"
    t.string "state", default: "open", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["external_pr_number"], name: "index_jobs_on_external_pr_number"
    t.index ["repository_id", "issue_number", "state"], name: "index_jobs_on_repository_id_and_issue_number_and_state"
    t.index ["repository_id", "state"], name: "index_jobs_on_repository_id_and_state"
    t.index ["repository_id"], name: "index_jobs_on_repository_id"
    t.index ["scheduled_task_id"], name: "index_jobs_on_scheduled_task_id"
    t.index ["user_id"], name: "index_jobs_on_user_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.text "last_poll_error"
    t.datetime "last_poll_started_at"
    t.string "last_poll_status"
    t.string "name", null: false
    t.string "owner", null: false
    t.boolean "polling_enabled", default: true, null: false
    t.string "trigger_label", default: "syrus", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["archived_at"], name: "index_repositories_on_archived_at"
    t.index ["user_id", "owner", "name"], name: "index_repositories_on_user_id_and_owner_and_name", unique: true
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "run_health_snapshots", force: :cascade do |t|
    t.integer  "run_id",                  null: false
    t.string   "run_state",               null: false
    t.datetime "last_heartbeat_at"
    t.integer  "heartbeat_age_seconds"
    t.datetime "last_log_at"
    t.integer  "log_count"
    t.text     "last_log_preview"
    t.integer  "agent_turns"
    t.string   "agent_outcome"
    t.integer  "agent_diff_bytes"
    t.string   "head_sha"
    t.string   "sq_job_state"
    t.text     "sq_error_class"
    t.text     "sq_error_message"
    t.text     "sq_error_backtrace"
    t.boolean  "worktree_exists"
    t.text     "worktree_git_status"
    t.text     "worktree_recent_commits"
    t.boolean  "claude_process_running"
    t.text     "claude_process_info"
    t.boolean  "branch_on_origin"
    t.boolean  "mcp_sidecar_alive"
    t.string   "health_status"
    t.text     "hint"
    t.datetime "created_at",              null: false
    t.datetime "updated_at",              null: false
    t.index ["created_at"],   name: "index_run_health_snapshots_on_created_at"
    t.index ["run_id"],       name: "index_run_health_snapshots_on_run_id"
  end

  create_table "run_diagnostics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "environment_snapshot"
    t.text "error_backtrace"
    t.string "error_class", null: false
    t.text "error_message"
    t.text "git_snapshot"
    t.text "repo_snapshot"
    t.integer "run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_run_diagnostics_on_created_at"
    t.index ["run_id"], name: "index_run_diagnostics_on_run_id", unique: true
  end

  create_table "runs", force: :cascade do |t|
    t.text "agent_diff"
    t.string "agent_outcome"
    t.text "agent_pr_body"
    t.string "agent_pr_title"
    t.text "agent_summary"
    t.integer "agent_turns"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "head_sha"
    t.integer "job_id", null: false
    t.datetime "last_heartbeat_at"
    t.string "parent_session_id"
    t.text "prompt"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.integer "step_id"
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "state"], name: "index_runs_on_job_id_and_state"
    t.index ["job_id"], name: "index_runs_on_job_id"
    t.index ["parent_session_id"], name: "index_runs_on_parent_session_id"
    t.index ["state", "last_heartbeat_at"], name: "index_runs_on_state_and_last_heartbeat_at"
    t.index ["step_id"], name: "index_runs_on_step_id"
  end

  create_table "scheduled_tasks", force: :cascade do |t|
    t.datetime "archived_at"
    t.integer "consecutive_failure_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "cron_expression"
    t.integer "cron_template_id"
    t.datetime "fire_at"
    t.string "kind", null: false
    t.datetime "last_fired_at"
    t.datetime "last_successful_fire_at"
    t.integer "minute_offset", default: 0, null: false
    t.string "name", null: false
    t.string "pr_pileup_policy", default: "skip", null: false
    t.text "prompt", null: false
    t.integer "repository_id", null: false
    t.string "state", default: "scheduled", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["archived_at"], name: "index_scheduled_tasks_on_archived_at"
    t.index ["cron_template_id"], name: "index_scheduled_tasks_on_cron_template_id"
    t.index ["repository_id"], name: "index_scheduled_tasks_on_repository_id"
    t.index ["state", "archived_at"], name: "index_scheduled_tasks_on_state_and_archived_at"
    t.index ["user_id"], name: "index_scheduled_tasks_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "kind", null: false
    t.bigint "next_step_id"
    t.integer "position", default: 0, null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["next_step_id"], name: "index_steps_on_next_step_id"
    t.index ["workflow_id", "position"], name: "index_steps_on_workflow_id_and_position"
    t.index ["workflow_id"], name: "index_steps_on_workflow_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.integer "agent_max_turns", default: 200, null: false
    t.string "api_token"
    t.string "claude_oauth_token"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.integer "gh_rate_limit_limit"
    t.datetime "gh_rate_limit_observed_at"
    t.integer "gh_rate_limit_remaining"
    t.datetime "gh_rate_limit_reset_at"
    t.string "gh_rate_limit_resource", limit: 32
    t.string "github_token"
    t.string "password_digest", null: false
    t.boolean "scheduling_paused", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "workflows", force: :cascade do |t|
    t.text "artifacts"
    t.datetime "cleaned_up_at"
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.integer "job_id", null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["cleaned_up_at"], name: "index_workflows_on_cleaned_up_at"
    t.index ["job_id", "created_at"], name: "index_workflows_on_job_id_and_created_at"
    t.index ["job_id"], name: "index_workflows_on_job_id"
  end

  add_foreign_key "admin_actions", "users"
  add_foreign_key "claude_sessions", "runs"
  add_foreign_key "cron_templates", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "job_logs", "runs"
  add_foreign_key "jobs", "repositories"
  add_foreign_key "jobs", "scheduled_tasks"
  add_foreign_key "jobs", "users"
  add_foreign_key "repositories", "users"
  add_foreign_key "run_diagnostics", "runs"
  add_foreign_key "run_health_snapshots", "runs"
  add_foreign_key "runs", "jobs"
  add_foreign_key "runs", "steps"
  add_foreign_key "scheduled_tasks", "cron_templates"
  add_foreign_key "scheduled_tasks", "repositories"
  add_foreign_key "scheduled_tasks", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "steps", "steps", column: "next_step_id"
  add_foreign_key "steps", "workflows"
  add_foreign_key "workflows", "jobs"
end
