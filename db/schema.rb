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

ActiveRecord::Schema[8.1].define(version: 2026_05_13_190100) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

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
    t.bigint "github_app_id"
    t.text "github_app_private_key_pem"
    t.datetime "github_app_registered_at"
    t.string "github_app_slug"
    t.text "github_app_webhook_secret"
    t.integer "grade_max_iterations", default: 5, null: false
    t.integer "max_job_failures", default: 3, null: false
    t.boolean "polling_paused", default: false, null: false
    t.boolean "runs_paused", default: false, null: false
    t.boolean "signups_open", default: false, null: false
    t.text "telegram_bot_token"
    t.text "telegram_webhook_secret"
    t.datetime "updated_at", null: false
    t.index ["github_app_id"], name: "index_app_settings_on_github_app_id", unique: true
  end

  create_table "chat_messages", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.json "content", null: false
    t.datetime "created_at", null: false
    t.integer "proposal_id"
    t.string "role", null: false
    t.string "tool_name"
    t.string "tool_use_id"
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["proposal_id"], name: "index_chat_messages_on_proposal_id"
  end

  create_table "chat_pending_actions", force: :cascade do |t|
    t.string "action"
    t.string "action_type"
    t.datetime "cancelled_at"
    t.integer "chat_session_id", null: false
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.json "payload", null: false
    t.datetime "rejected_at"
    t.string "requested_by", default: "agent", null: false
    t.integer "repository_id", null: false
    t.bigint "result_id"
    t.string "result_type"
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["chat_session_id", "state"], name: "index_chat_pending_actions_on_chat_session_id_and_state"
    t.index ["chat_session_id", "state", "created_at"], name: "index_chat_pending_actions_on_session_state"
    t.index ["chat_session_id"], name: "index_chat_pending_actions_on_chat_session_id"
    t.index ["repository_id"], name: "index_chat_pending_actions_on_repository_id"
    t.index ["result_type", "result_id"], name: "index_chat_pending_actions_on_result_type_and_result_id"
    t.index ["user_id"], name: "index_chat_pending_actions_on_user_id"
  end

  create_table "chat_proposal_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "depends_on_id", null: false
    t.integer "proposal_id", null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_id"], name: "index_chat_proposal_dependencies_on_depends_on_id"
    t.index ["proposal_id", "depends_on_id"], name: "index_chat_prop_deps_on_proposal_and_depends_on", unique: true
    t.index ["proposal_id"], name: "index_chat_proposal_dependencies_on_proposal_id"
  end

  create_table "chat_proposals", force: :cascade do |t|
    t.text "body", null: false
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.datetime "filed_at"
    t.integer "github_issue_number"
    t.integer "job_id"
    t.string "kind", default: "syrus_issue", null: false
    t.string "labels"
    t.string "slug", null: false
    t.string "state", default: "pending", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "slug"], name: "index_chat_proposals_on_chat_session_id_and_slug", unique: true
    t.index ["chat_session_id", "state"], name: "index_chat_proposals_on_chat_session_id_and_state"
    t.index ["chat_session_id"], name: "index_chat_proposals_on_chat_session_id"
    t.index ["job_id"], name: "index_chat_proposals_on_job_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "cumulative_cost_usd", precision: 12, scale: 6, default: "0.0", null: false
    t.integer "cumulative_input_tokens", default: 0, null: false
    t.integer "cumulative_output_tokens", default: 0, null: false
    t.datetime "last_message_at"
    t.integer "repository_id", null: false
    t.datetime "stop_requested_at"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["repository_id", "last_message_at"], name: "index_chat_sessions_on_repository_id_and_last_message_at"
    t.index ["repository_id"], name: "index_chat_sessions_on_repository_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
  end

  create_table "chat_whiteboards", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_edited_at"
    t.json "scene_json", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["chat_session_id"], name: "index_chat_whiteboards_on_chat_session_id", unique: true
  end

  create_table "repository_whiteboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "repository_id", null: false
    t.json "scene_json", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["repository_id"], name: "index_repository_whiteboards_on_repository_id", unique: true
  end

  create_table "claude_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", default: "claude", null: false
    t.integer "resumable_id"
    t.string "resumable_type"
    t.integer "run_id"
    t.string "session_id", null: false
    t.text "transcript_jsonl", limit: 67108864
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_claude_sessions_on_created_at"
    t.index ["resumable_type", "resumable_id"], name: "index_claude_sessions_on_resumable", unique: true
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

  create_table "installations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "account_login", null: false
    t.string "account_type", null: false
    t.text "cached_token"
    t.datetime "cached_token_expires_at"
    t.datetime "created_at", null: false
    t.bigint "github_installation_id", null: false
    t.datetime "installed_at", null: false
    t.datetime "removed_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["github_installation_id"], name: "index_installations_on_github_installation_id", unique: true
    t.index ["user_id"], name: "index_installations_on_user_id"
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

  create_table "job_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_by_user_id"
    t.integer "depends_on_job_id"
    t.integer "job_id", null: false
    t.string "source", null: false
    t.integer "unresolved_number"
    t.string "unresolved_owner"
    t.string "unresolved_repo"
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_job_dependencies_on_created_by_user_id"
    t.index ["depends_on_job_id"], name: "index_job_dependencies_on_depends_on_job_id"
    t.index ["job_id", "depends_on_job_id"], name: "index_job_dependencies_on_job_id_and_depends_on_job_id", unique: true
    t.index ["job_id", "unresolved_owner", "unresolved_repo", "unresolved_number"], name: "index_job_deps_on_unique_unresolved_per_job", unique: true
    t.index ["job_id"], name: "index_job_dependencies_on_job_id"
    t.index ["unresolved_owner", "unresolved_repo", "unresolved_number"], name: "index_job_deps_on_unresolved_reference"
  end

  create_table "job_attachments", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.integer "job_id", null: false
    t.string "source_url", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "source_url"], name: "index_job_attachments_on_job_id_and_source_url", unique: true
    t.index ["job_id"], name: "index_job_attachments_on_job_id"
  end

  create_table "job_logs", force: :cascade do |t|
    t.text "chunk", limit: 16777215, null: false
    t.datetime "created_at", null: false
    t.string "kind"
    t.integer "run_id", null: false
    t.integer "sequence", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "sequence"], name: "index_job_logs_on_run_id_and_sequence", unique: true
    t.index ["run_id"], name: "index_job_logs_on_run_id"
  end

  create_table "jobs", force: :cascade do |t|
    t.string "agent_provider", null: false
    t.string "branch_name"
    t.string "closure_reason"
    t.datetime "created_at", null: false
    t.string "credential_mode", default: "pat", null: false
    t.datetime "dependencies_overridden_at"
    t.integer "dependencies_overridden_by_user_id"
    t.integer "external_pr_number"
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.text "issue_body"
    t.integer "issue_number"
    t.string "issue_title"
    t.string "kind", default: "issue", null: false
    t.string "last_ci_handled_sha"
    t.datetime "last_feedback_addressed_at"
    t.datetime "last_seen_comment_at"
    t.boolean "operator_chat_disabled", default: false, null: false
    t.boolean "pr_mergeable"
    t.datetime "pr_mergeable_checked_at"
    t.integer "pr_number"
    t.string "priority", default: "medium", null: false
    t.integer "repository_id", null: false
    t.integer "scheduled_task_id"
    t.boolean "skip_prepare", default: false, null: false
    t.datetime "started_at"
    t.string "state", default: "open", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["credential_mode"], name: "index_jobs_on_credential_mode"
    t.index ["dependencies_overridden_by_user_id"], name: "index_jobs_on_dependencies_overridden_by_user_id"
    t.index ["external_pr_number"], name: "index_jobs_on_external_pr_number"
    t.index ["repository_id", "issue_number", "state"], name: "index_jobs_on_repository_id_and_issue_number_and_state"
    t.index ["repository_id", "state"], name: "index_jobs_on_repository_id_and_state"
    t.index ["repository_id"], name: "index_jobs_on_repository_id"
    t.index ["scheduled_task_id"], name: "index_jobs_on_scheduled_task_id"
    t.index ["user_id"], name: "index_jobs_on_user_id"
  end

  create_table "operator_questions", force: :cascade do |t|
    t.datetime "asked_at", null: false
    t.json "context", null: false
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.integer "run_id", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["job_id"], name: "index_operator_questions_on_job_id"
    t.index ["run_id", "asked_at"], name: "index_operator_questions_on_run_id_and_asked_at"
    t.index ["run_id"], name: "index_operator_questions_on_run_id"
    t.index ["workflow_id"], name: "index_operator_questions_on_workflow_id"
  end

  create_table "operator_responses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "operator_question_id", null: false
    t.datetime "responded_at", null: false
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["operator_question_id", "responded_at"], name: "index_operator_responses_on_question_and_responded_at"
    t.index ["operator_question_id"], name: "index_operator_responses_on_operator_question_id"
  end

  create_table "recurring_tasks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cron_expression", null: false
    t.boolean "enabled", default: true, null: false
    t.string "label", null: false
    t.datetime "next_fire_at", null: false
    t.text "prompt", null: false
    t.integer "repository_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["enabled", "next_fire_at"], name: "index_recurring_tasks_on_enabled_and_next_fire_at"
    t.index ["repository_id"], name: "index_recurring_tasks_on_repository_id"
    t.index ["user_id"], name: "index_recurring_tasks_on_user_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.string "agent_provider"
    t.string "allow_operator_chat", default: "disabled", null: false
    t.datetime "archived_at"
    t.boolean "auto_merge_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.bigint "github_owner_id"
    t.bigint "github_repository_id"
    t.integer "installation_id"
    t.text "last_poll_error"
    t.datetime "last_poll_started_at"
    t.string "last_poll_status"
    t.string "name", null: false
    t.string "owner", null: false
    t.boolean "polling_enabled", default: true, null: false
    t.boolean "pr_cost_footer_enabled", default: true, null: false
    t.boolean "prepare_enabled", default: true, null: false
    t.string "trigger_label", default: "syrus", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["allow_operator_chat"], name: "index_repositories_on_allow_operator_chat"
    t.index ["archived_at"], name: "index_repositories_on_archived_at"
    t.index ["github_owner_id"], name: "index_repositories_on_github_owner_id"
    t.index ["github_repository_id"], name: "index_repositories_on_github_repository_id"
    t.index ["installation_id"], name: "index_repositories_on_installation_id"
    t.index ["user_id", "owner", "name"], name: "index_repositories_on_user_id_and_owner_and_name", unique: true
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "repository_documents", force: :cascade do |t|
    t.text "content_cache", limit: 65536
    t.datetime "content_cached_at"
    t.datetime "created_at", null: false
    t.string "google_docs_url"
    t.string "kind", null: false
    t.integer "repository_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["repository_id", "created_at"], name: "index_repository_documents_on_repository_id_and_created_at"
    t.index ["repository_id"], name: "index_repository_documents_on_repository_id"
    t.index ["user_id"], name: "index_repository_documents_on_user_id"
  end

  create_table "repository_notes", force: :cascade do |t|
    t.string "author", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "removed_at"
    t.integer "repository_id", null: false
    t.index ["repository_id", "removed_at", "created_at"], name: "index_repo_notes_on_active_order"
    t.index ["repository_id"], name: "index_repository_notes_on_repository_id"
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

  create_table "run_health_snapshots", force: :cascade do |t|
    t.integer "agent_diff_bytes"
    t.string "agent_outcome"
    t.integer "agent_turns"
    t.boolean "branch_on_origin"
    t.text "claude_process_info"
    t.boolean "claude_process_running"
    t.datetime "created_at", null: false
    t.string "head_sha"
    t.string "health_status"
    t.integer "heartbeat_age_seconds"
    t.text "hint"
    t.datetime "last_heartbeat_at"
    t.datetime "last_log_at"
    t.text "last_log_preview"
    t.integer "log_count"
    t.boolean "mcp_sidecar_alive"
    t.integer "run_id", null: false
    t.string "run_state", null: false
    t.text "sq_error_backtrace"
    t.text "sq_error_class"
    t.text "sq_error_message"
    t.string "sq_job_state"
    t.datetime "updated_at", null: false
    t.boolean "worktree_exists"
    t.text "worktree_git_status"
    t.text "worktree_recent_commits"
    t.index ["created_at"], name: "index_run_health_snapshots_on_created_at"
    t.index ["run_id"], name: "index_run_health_snapshots_on_run_id"
  end

  create_table "runs", force: :cascade do |t|
    t.text "agent_diff", limit: 16777215
    t.string "agent_outcome"
    t.text "agent_pr_body"
    t.string "agent_pr_title"
    t.string "agent_provider", default: "claude", null: false
    t.text "agent_summary"
    t.integer "agent_turns"
    t.integer "cache_creation_input_tokens"
    t.integer "cache_read_input_tokens"
    t.decimal "cost_usd", precision: 12, scale: 6
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "head_sha"
    t.integer "input_tokens"
    t.integer "iteration", default: 1, null: false
    t.integer "job_id", null: false
    t.datetime "last_heartbeat_at"
    t.boolean "nudge_sent", default: false, null: false
    t.integer "output_tokens"
    t.text "operator_chat_response"
    t.string "operator_chat_thread_id"
    t.string "parent_session_id"
    t.text "prompt"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.integer "step_id"
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "state"], name: "index_runs_on_job_id_and_state"
    t.index ["job_id"], name: "index_runs_on_job_id"
    t.index ["operator_chat_thread_id"], name: "index_runs_on_operator_chat_thread_id"
    t.index ["parent_session_id"], name: "index_runs_on_parent_session_id"
    t.index ["state", "last_heartbeat_at"], name: "index_runs_on_state_and_last_heartbeat_at"
    t.index ["state", "nudge_sent", "created_at"], name: "index_runs_on_operator_nudge_window"
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
    t.integer "iteration", default: 1, null: false
    t.string "kind", null: false
    t.string "loop_id"
    t.string "cancellation_reason"
    t.bigint "next_step_id"
    t.integer "position", default: 0, null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["next_step_id"], name: "index_steps_on_next_step_id"
    t.index ["workflow_id", "loop_id", "iteration"], name: "index_steps_on_workflow_id_and_loop_id_and_iteration"
    t.index ["workflow_id", "position"], name: "index_steps_on_workflow_id_and_position"
    t.index ["workflow_id"], name: "index_steps_on_workflow_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.integer "agent_max_turns", default: 200, null: false
    t.string "agent_provider", default: "claude", null: false
    t.string "api_token"
    t.string "claude_oauth_token"
    t.string "codex_api_key"
    t.text "codex_auth_json"
    t.string "codex_auth_mode", default: "api_key", null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "gh_api_blocked_at"
    t.text "gh_api_blocked_reason"
    t.integer "gh_rate_limit_limit"
    t.datetime "gh_rate_limit_observed_at"
    t.integer "gh_rate_limit_remaining"
    t.datetime "gh_rate_limit_reset_at"
    t.string "gh_rate_limit_resource", limit: 32
    t.string "github_handle"
    t.string "github_token"
    t.string "name"
    t.string "password_digest", null: false
    t.boolean "scheduling_paused", default: false, null: false
    t.text "telegram_chat_id"
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "whiteboards", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_edited_at"
    t.json "scene_json", default: {"elements"=>[]}, null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["chat_session_id"], name: "index_whiteboards_on_chat_session_id", unique: true
  end

  create_table "workflows", force: :cascade do |t|
    t.string "agent_provider", default: "claude", null: false
    t.text "artifacts"
    t.text "chain_template"
    t.datetime "cleaned_up_at"
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.string "failure_reason"
    t.integer "job_id", null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["cleaned_up_at"], name: "index_workflows_on_cleaned_up_at"
    t.index ["job_id", "created_at"], name: "index_workflows_on_job_id_and_created_at"
    t.index ["job_id"], name: "index_workflows_on_job_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "admin_actions", "users"
  add_foreign_key "chat_messages", "chat_proposals", column: "proposal_id"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_pending_actions", "chat_sessions"
  add_foreign_key "chat_pending_actions", "repositories"
  add_foreign_key "chat_pending_actions", "users"
  add_foreign_key "chat_proposal_dependencies", "chat_proposals", column: "depends_on_id"
  add_foreign_key "chat_proposal_dependencies", "chat_proposals", column: "proposal_id"
  add_foreign_key "chat_proposals", "chat_sessions"
  add_foreign_key "chat_proposals", "jobs"
  add_foreign_key "chat_sessions", "repositories"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "chat_whiteboards", "chat_sessions"
  add_foreign_key "claude_sessions", "runs"
  add_foreign_key "cron_templates", "users"
  add_foreign_key "installations", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "job_dependencies", "jobs"
  add_foreign_key "job_dependencies", "jobs", column: "depends_on_job_id"
  add_foreign_key "job_dependencies", "users", column: "created_by_user_id"
  add_foreign_key "job_attachments", "jobs"
  add_foreign_key "job_logs", "runs"
  add_foreign_key "jobs", "repositories"
  add_foreign_key "jobs", "scheduled_tasks"
  add_foreign_key "jobs", "users"
  add_foreign_key "repository_whiteboards", "repositories"
  add_foreign_key "jobs", "users", column: "dependencies_overridden_by_user_id"
  add_foreign_key "operator_questions", "jobs"
  add_foreign_key "operator_questions", "runs"
  add_foreign_key "operator_questions", "workflows"
  add_foreign_key "operator_responses", "operator_questions"
  add_foreign_key "recurring_tasks", "repositories"
  add_foreign_key "recurring_tasks", "users"
  add_foreign_key "repositories", "installations"
  add_foreign_key "repositories", "users"
  add_foreign_key "repository_documents", "repositories"
  add_foreign_key "repository_documents", "users"
  add_foreign_key "repository_notes", "repositories"
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
  add_foreign_key "whiteboards", "chat_sessions"
  add_foreign_key "workflows", "jobs"
end
