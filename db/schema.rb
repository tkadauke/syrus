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

ActiveRecord::Schema[8.1].define(version: 2026_08_02_023000) do
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
    t.integer "user_id", null: false
    t.index ["performed_at"], name: "index_admin_actions_on_performed_at"
    t.index ["user_id"], name: "index_admin_actions_on_user_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.integer "adversarial_review_rounds", default: 0, null: false
    t.integer "chat_coding_workspace_budget_mb", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "github_app_id"
    t.text "github_app_private_key_pem"
    t.datetime "github_app_registered_at"
    t.string "github_app_slug"
    t.integer "grade_max_iterations", default: 5, null: false
    t.integer "main_concern_report_threshold", default: 2, null: false
    t.integer "max_concurrent_agent_runs", default: 0, null: false
    t.integer "max_concurrent_landing_grader_runs", default: 2, null: false
    t.integer "max_job_failures", default: 3, null: false
    t.boolean "merge_train_enabled", default: false, null: false
    t.integer "merge_train_max_size", default: 20, null: false
    t.string "mode", default: "advanced"
    t.datetime "mode_configured_at"
    t.boolean "polling_paused", default: false, null: false
    t.integer "proactive_rebase_commit_threshold", default: 20, null: false
    t.string "report_issue_repo_slug", default: "tkadauke/syrus", null: false
    t.boolean "runs_paused", default: false, null: false
    t.boolean "signups_open", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "video_retention_days", default: 7, null: false
    t.integer "video_storage_budget_mb", default: 2048, null: false
    t.index ["github_app_id"], name: "index_app_settings_on_github_app_id", unique: true
  end

  create_table "auto_retry_attempts", force: :cascade do |t|
    t.string "agent_provider", null: false
    t.integer "attempt_number", null: false
    t.datetime "created_at", null: false
    t.string "failure_classification", null: false
    t.integer "job_id", null: false
    t.datetime "performed_at"
    t.string "retry_kind", null: false
    t.integer "run_id"
    t.datetime "scheduled_at", null: false
    t.string "skipped_reason"
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["job_id", "agent_provider", "failure_classification"], name: "index_auto_retry_attempts_on_budget"
    t.index ["job_id"], name: "index_auto_retry_attempts_on_job_id"
    t.index ["run_id"], name: "index_auto_retry_attempts_on_run_id"
    t.index ["workflow_id", "retry_kind"], name: "index_auto_retry_attempts_on_workflow_retry_kind"
    t.index ["workflow_id"], name: "index_auto_retry_attempts_on_workflow_id"
  end

  create_table "chat_agent_questions", force: :cascade do |t|
    t.text "answer"
    t.datetime "answered_at"
    t.datetime "asked_at", null: false
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expired_at"
    t.json "options"
    t.text "question", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "answered_at", "expired_at"], name: "idx_chat_agent_questions_active"
    t.index ["chat_session_id"], name: "index_chat_agent_questions_on_chat_session_id"
  end

  create_table "chat_attachments", force: :cascade do |t|
    t.integer "attachable_id", null: false
    t.string "attachable_type", null: false
    t.datetime "attached_at", null: false
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_chat_attachments_on_attachable"
    t.index ["chat_session_id", "attachable_type", "attachable_id"], name: "index_chat_attachments_on_session_and_attachable", unique: true
    t.index ["chat_session_id"], name: "index_chat_attachments_on_chat_session_id"
  end

  create_table "chat_bookmarks", force: :cascade do |t|
    t.integer "chat_message_id", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "label", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_message_id"], name: "index_chat_bookmarks_on_chat_message_id"
  end

  create_table "chat_memories", force: :cascade do |t|
    t.string "author"
    t.float "confidence"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.integer "deleted_by_user_id"
    t.binary "embedding"
    t.datetime "expires_at"
    t.string "kind", null: false
    t.datetime "last_verified_at"
    t.boolean "published", default: false, null: false
    t.string "scope", null: false
    t.bigint "scope_id"
    t.bigint "source_id"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "visibility"
    t.index ["deleted_at"], name: "index_chat_memories_on_deleted_at"
    t.index ["deleted_by_user_id"], name: "index_chat_memories_on_deleted_by_user_id"
    t.index ["scope_id", "published", "scope"], name: "index_chat_memories_on_scope_id_and_published_and_scope"
    t.index ["user_id", "scope", "scope_id"], name: "index_chat_memories_on_user_id_and_scope_and_scope_id"
  end

  create_table "chat_memory_audit_events", force: :cascade do |t|
    t.string "actor_kind", null: false
    t.integer "actor_run_id"
    t.integer "actor_user_id"
    t.integer "chat_memory_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.float "new_confidence"
    t.text "new_content"
    t.string "new_kind"
    t.float "previous_confidence"
    t.text "previous_content"
    t.string "previous_kind"
    t.index ["actor_run_id"], name: "index_chat_memory_audit_events_on_actor_run_id"
    t.index ["actor_user_id"], name: "index_chat_memory_audit_events_on_actor_user_id"
    t.index ["chat_memory_id"], name: "index_chat_memory_audit_events_on_chat_memory_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.json "content", null: false
    t.datetime "created_at", null: false
    t.bigint "pending_action_id"
    t.integer "proposal_id"
    t.string "role", null: false
    t.string "tool_name"
    t.string "tool_use_id"
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at", "id"], name: "idx_chat_messages_session_created_id"
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id", "id"], name: "index_chat_messages_on_session_id_and_id"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["pending_action_id"], name: "index_chat_messages_on_pending_action_id"
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
    t.integer "repository_id"
    t.string "requested_by", default: "agent", null: false
    t.bigint "result_id"
    t.string "result_type"
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["chat_session_id", "state", "created_at"], name: "index_chat_pending_actions_on_session_state"
    t.index ["chat_session_id", "state"], name: "index_chat_pending_actions_on_chat_session_id_and_state"
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
    t.integer "child_position"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.json "depends_on_epic_ids"
    t.json "depends_on_job_ids"
    t.datetime "discarded_at"
    t.datetime "edited_at"
    t.text "epic_depends_on_tokens"
    t.integer "epic_id"
    t.datetime "filed_at"
    t.integer "github_issue_number"
    t.integer "job_id"
    t.string "kind", default: "syrus_issue", null: false
    t.string "labels"
    t.json "media_ids", null: false
    t.boolean "nonlinear_dependency_override", default: false, null: false
    t.integer "parent_proposal_id"
    t.datetime "rejected_at"
    t.integer "repository_id"
    t.string "slug", null: false
    t.string "state", default: "proposed", null: false
    t.integer "target_epic_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.datetime "withdrawn_at"
    t.index ["chat_session_id", "slug"], name: "index_chat_proposals_on_chat_session_id_and_slug", unique: true
    t.index ["chat_session_id", "state"], name: "index_chat_proposals_on_chat_session_id_and_state"
    t.index ["chat_session_id"], name: "index_chat_proposals_on_chat_session_id"
    t.index ["epic_id"], name: "index_chat_proposals_on_epic_id"
    t.index ["job_id"], name: "index_chat_proposals_on_job_id"
    t.index ["parent_proposal_id"], name: "index_chat_proposals_on_parent_proposal_id"
    t.index ["repository_id"], name: "index_chat_proposals_on_repository_id"
    t.index ["target_epic_id"], name: "index_chat_proposals_on_target_epic_id"
  end

  create_table "chat_queued_messages", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.json "content", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "delivered_at", "created_at", "id"], name: "idx_chat_queued_messages_pending_order"
    t.index ["chat_session_id"], name: "index_chat_queued_messages_on_chat_session_id"
  end

  create_table "chat_scratchpad_items", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "position", "id"], name: "index_chat_scratchpad_items_on_session_position"
    t.index ["chat_session_id"], name: "index_chat_scratchpad_items_on_chat_session_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.string "chat_effort"
    t.string "chat_model"
    t.string "chat_provider"
    t.string "coding_checkout_branch"
    t.text "coding_checkout_prepare_failure"
    t.datetime "coding_checkout_prepare_finished_at"
    t.datetime "coding_checkout_prepare_started_at"
    t.string "coding_checkout_prepare_status"
    t.boolean "coding_checkout_uncommitted", default: false, null: false
    t.string "coding_relay_address"
    t.string "coding_relay_token"
    t.datetime "created_at", null: false
    t.decimal "cumulative_cost_usd", precision: 12, scale: 6, default: "0.0", null: false
    t.bigint "cumulative_input_tokens", default: 0, null: false
    t.bigint "cumulative_output_tokens", default: 0, null: false
    t.string "daemon_branch"
    t.boolean "daemon_connected", default: false, null: false
    t.string "daemon_repo"
    t.datetime "hidden_at"
    t.datetime "last_message_at"
    t.datetime "last_read_at"
    t.string "local_daemon_branch"
    t.string "local_daemon_repo"
    t.string "local_daemon_state"
    t.string "mode"
    t.boolean "onboarding", default: false, null: false
    t.boolean "pinned", default: false, null: false
    t.text "pinned_context"
    t.string "share_token"
    t.datetime "stop_requested_at"
    t.string "suggested_next_step"
    t.string "system_kind"
    t.string "title"
    t.boolean "turn_in_flight", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "workspace_path"
    t.index ["cumulative_cost_usd"], name: "idx_chat_sessions_spending_cost"
    t.index ["share_token"], name: "index_chat_sessions_on_share_token", unique: true
    t.index ["turn_in_flight", "last_message_at"], name: "idx_chat_sessions_stale_turns"
    t.index ["user_id", "cumulative_cost_usd"], name: "idx_chat_sessions_spending_user_cost"
    t.index ["user_id", "hidden_at"], name: "index_chat_sessions_on_user_id_and_hidden_at"
    t.index ["user_id", "system_kind"], name: "index_chat_sessions_on_user_id_and_system_kind", unique: true
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
    t.index ["workspace_path"], name: "index_chat_sessions_on_workspace_path"
  end

  create_table "chat_video_walkthroughs", force: :cascade do |t|
    t.json "analysis"
    t.datetime "analyzed_at"
    t.bigint "byte_size"
    t.integer "chat_session_id", null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.integer "duration_seconds"
    t.text "error_message"
    t.datetime "gemini_file_active_at"
    t.string "gemini_file_content_type"
    t.string "gemini_file_uri"
    t.text "note"
    t.string "state", default: "uploaded", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["chat_session_id"], name: "index_chat_video_walkthroughs_on_chat_session_id"
    t.index ["state"], name: "index_chat_video_walkthroughs_on_state"
    t.index ["user_id"], name: "index_chat_video_walkthroughs_on_user_id"
  end

  create_table "chat_wakeups", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "fire_at", null: false
    t.text "prompt", null: false
    t.string "state", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["chat_session_id"], name: "index_chat_wakeups_on_chat_session_id"
    t.index ["state", "fire_at"], name: "index_chat_wakeups_on_state_and_fire_at"
    t.index ["user_id"], name: "index_chat_wakeups_on_user_id"
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

  create_table "claude_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "normalized_messages"
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

  create_table "coverage_snapshots", force: :cascade do |t|
    t.string "branch", null: false
    t.decimal "branches_pct", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.json "data"
    t.integer "file_count"
    t.decimal "functions_pct", precision: 5, scale: 2
    t.integer "job_id"
    t.decimal "lines_pct", precision: 5, scale: 2
    t.decimal "pr_delta_pct", precision: 5, scale: 2
    t.integer "repository_id", null: false
    t.string "sha", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["job_id"], name: "index_coverage_snapshots_on_job_id"
    t.index ["repository_id", "branch", "created_at"], name: "idx_coverage_snapshots_repo_branch_created"
    t.index ["repository_id", "branch"], name: "index_coverage_snapshots_on_repository_id_and_branch"
    t.index ["repository_id", "created_at"], name: "index_coverage_snapshots_on_repository_id_and_created_at"
    t.index ["repository_id"], name: "index_coverage_snapshots_on_repository_id"
    t.index ["workflow_id"], name: "index_coverage_snapshots_on_workflow_id"
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

  create_table "documents", force: :cascade do |t|
    t.integer "attachable_id", null: false
    t.string "attachable_type", null: false
    t.bigint "byte_size"
    t.text "content_cache", limit: 65536
    t.datetime "content_cached_at"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename"
    t.string "google_doc_url"
    t.string "kind", default: "file", null: false
    t.string "source_url"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["attachable_type", "attachable_id", "created_at"], name: "index_documents_on_attachable_and_created_at"
    t.index ["attachable_type", "attachable_id", "source_url"], name: "index_documents_on_attachable_and_source_url", unique: true
    t.index ["user_id"], name: "index_documents_on_user_id"
  end

  create_table "epic_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "depends_on_epic_id"
    t.integer "depends_on_job_id"
    t.boolean "derived", default: false, null: false
    t.integer "epic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_epic_id"], name: "index_epic_dependencies_on_depends_on_epic_id"
    t.index ["depends_on_job_id"], name: "index_epic_dependencies_on_depends_on_job_id"
    t.index ["epic_id", "depends_on_epic_id", "derived"], name: "index_epic_deps_on_epic_and_depends_on_and_derived", unique: true
    t.index ["epic_id"], name: "index_epic_dependencies_on_epic_id"
  end

  create_table "epic_versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description_after"
    t.text "description_before"
    t.integer "epic_id", null: false
    t.text "title_after"
    t.text "title_before"
    t.integer "user_id"
    t.index ["epic_id"], name: "index_epic_versions_on_epic_id"
    t.index ["user_id"], name: "index_epic_versions_on_user_id"
  end

  create_table "epics", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "auto_approve_mode", default: "never", null: false
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "done_at"
    t.string "epic_dependency_policy", default: "linear", null: false
    t.string "github_issue_url"
    t.integer "number", null: false
    t.integer "owner_id"
    t.integer "owner_user_id"
    t.json "pending_epic_dependency_refs", null: false
    t.bigint "reconciliation_job_id"
    t.string "reconciliation_mode"
    t.integer "repository_id", null: false
    t.string "slug"
    t.string "state", default: "backlog", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.datetime "user_approved_at"
    t.integer "user_id", null: false
    t.index ["claimed_at"], name: "index_epics_on_claimed_at"
    t.index ["number"], name: "index_epics_on_number", unique: true
    t.index ["owner_id"], name: "index_epics_on_owner_id"
    t.index ["owner_user_id"], name: "index_epics_on_owner_user_id"
    t.index ["reconciliation_job_id"], name: "index_epics_on_reconciliation_job_id"
    t.index ["repository_id"], name: "index_epics_on_repository_id"
    t.index ["slug"], name: "index_epics_on_slug", unique: true
    t.index ["user_id", "state"], name: "index_epics_on_user_id_and_state"
    t.index ["user_id"], name: "index_epics_on_user_id"
  end

  create_table "features", force: :cascade do |t|
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.boolean "default_enabled", default: false, null: false
    t.text "description"
    t.boolean "enabled", default: false, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_features_on_slug", unique: true
  end

  create_table "filter_usages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "filter_node", null: false
    t.string "fingerprint", null: false
    t.string "label", null: false
    t.datetime "last_used_at", null: false
    t.string "subject", null: false
    t.string "surface", null: false
    t.datetime "updated_at", null: false
    t.integer "use_count", default: 0, null: false
    t.integer "user_id", null: false
    t.index ["user_id", "surface", "subject", "fingerprint"], name: "index_filter_usages_on_user_surface_subject_fingerprint", unique: true
    t.index ["user_id", "surface", "subject", "last_used_at"], name: "index_filter_usages_on_user_surface_subject_recent"
    t.index ["user_id"], name: "index_filter_usages_on_user_id"
  end

  create_table "grader_conclusions", force: :cascade do |t|
    t.datetime "checked_at", null: false
    t.string "commit_sha", limit: 64, null: false
    t.datetime "created_at", null: false
    t.float "duration_s"
    t.integer "exit_code"
    t.string "grader_fingerprint", limit: 64, null: false
    t.string "grader_name", limit: 128, null: false
    t.bigint "job_id"
    t.bigint "log_bytes"
    t.string "log_path", limit: 1024
    t.json "metadata"
    t.bigint "repository_id", null: false
    t.boolean "required"
    t.bigint "run_id"
    t.string "status", limit: 32, null: false
    t.bigint "step_id"
    t.boolean "timed_out", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "workflow_id"
    t.index ["repository_id", "commit_sha", "grader_fingerprint", "status"], name: "idx_grader_conclusions_success_lookup"
    t.index ["repository_id", "grader_name", "status", "created_at"], name: "idx_grader_conclusions_history_lookup"
    t.index ["run_id"], name: "index_grader_conclusions_on_run_id"
    t.index ["workflow_id"], name: "index_grader_conclusions_on_workflow_id"
  end

  create_table "input_sources", force: :cascade do |t|
    t.json "config", null: false
    t.datetime "created_at", null: false
    t.text "credentials"
    t.boolean "polling_enabled", default: true, null: false
    t.integer "repository_id", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["repository_id", "type"], name: "index_input_sources_on_repository_and_type", unique: true
    t.index ["repository_id"], name: "index_input_sources_on_repository_id"
    t.index ["user_id"], name: "index_input_sources_on_user_id"
  end

  create_table "insight_schedule_configs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.integer "max_jobs_since_last_run", default: 10, null: false
    t.integer "min_jobs_since_last_run", default: 5, null: false
    t.integer "repository_id", null: false
    t.datetime "updated_at", null: false
    t.index ["repository_id"], name: "index_insight_schedule_configs_on_repository_id", unique: true
  end

  create_table "insight_suggestions", force: :cascade do |t|
    t.datetime "accepted_at"
    t.string "category", null: false
    t.float "confidence", default: 0.5, null: false
    t.datetime "created_at", null: false
    t.integer "created_job_id"
    t.datetime "dismissed_at"
    t.json "evidence"
    t.integer "job_id", null: false
    t.text "memory_suggestion"
    t.integer "repository_id", null: false
    t.string "severity", default: "medium", null: false
    t.string "state", default: "pending", null: false
    t.text "suggested_prompt"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_job_id"], name: "index_insight_suggestions_on_created_job_id"
    t.index ["job_id"], name: "index_insight_suggestions_on_job_id"
    t.index ["repository_id", "created_at"], name: "index_insight_suggestions_on_repository_id_and_created_at"
    t.index ["repository_id"], name: "index_insight_suggestions_on_repository_id"
    t.index ["state"], name: "index_insight_suggestions_on_state"
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

  create_table "instance_versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "data_root_available_bytes"
    t.string "data_root_path"
    t.bigint "data_root_total_bytes"
    t.integer "data_root_used_percent"
    t.datetime "finished_at"
    t.string "hostname", null: false
    t.datetime "last_heartbeat_at"
    t.string "outcome"
    t.string "role", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["finished_at"], name: "index_instance_versions_on_finished_at"
    t.index ["hostname", "role"], name: "index_instance_versions_on_hostname_and_role", unique: true
    t.index ["last_heartbeat_at"], name: "index_instance_versions_on_last_heartbeat_at"
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

  create_table "job_approvals", force: :cascade do |t|
    t.datetime "approved_at", null: false
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["job_id", "user_id"], name: "index_job_approvals_on_job_id_and_user_id", unique: true
    t.index ["job_id"], name: "index_job_approvals_on_job_id"
    t.index ["user_id"], name: "index_job_approvals_on_user_id"
  end

  create_table "job_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "created_by_user_id"
    t.integer "depends_on_epic_id"
    t.integer "depends_on_job_id"
    t.integer "job_id", null: false
    t.string "source", null: false
    t.integer "unresolved_chat_proposal_id"
    t.integer "unresolved_number"
    t.string "unresolved_owner"
    t.string "unresolved_repo"
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_job_dependencies_on_created_by_user_id"
    t.index ["depends_on_epic_id"], name: "index_job_dependencies_on_depends_on_epic_id"
    t.index ["depends_on_job_id"], name: "index_job_dependencies_on_depends_on_job_id"
    t.index ["job_id", "depends_on_job_id"], name: "index_job_dependencies_on_job_id_and_depends_on_job_id", unique: true
    t.index ["job_id", "unresolved_chat_proposal_id"], name: "index_job_deps_on_unresolved_proposal_per_job", unique: true, where: "depends_on_job_id IS NULL AND unresolved_chat_proposal_id IS NOT NULL"
    t.index ["job_id", "unresolved_owner", "unresolved_repo", "unresolved_number"], name: "index_job_deps_on_unique_unresolved_per_job", unique: true, where: "depends_on_job_id IS NULL"
    t.index ["job_id"], name: "index_job_dependencies_on_job_id"
    t.index ["unresolved_chat_proposal_id"], name: "index_job_dependencies_on_unresolved_chat_proposal_id"
    t.index ["unresolved_owner", "unresolved_repo", "unresolved_number"], name: "index_job_deps_on_unresolved_reference", where: "unresolved_owner IS NOT NULL"
  end

  create_table "job_deployment_stage_statuses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.datetime "reached_at", null: false
    t.string "stage_name", null: false
    t.string "tag_sha"
    t.datetime "updated_at", null: false
    t.index ["job_id", "stage_name"], name: "index_job_deployment_stage_statuses_on_job_id_and_stage_name", unique: true
    t.index ["job_id"], name: "index_job_deployment_stage_statuses_on_job_id"
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

  create_table "job_pins", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["job_id"], name: "index_job_pins_on_job_id"
    t.index ["user_id", "created_at"], name: "index_job_pins_on_user_id_and_created_at"
    t.index ["user_id", "job_id"], name: "index_job_pins_on_user_id_and_job_id", unique: true
    t.index ["user_id"], name: "index_job_pins_on_user_id"
  end

  create_table "job_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.integer "tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "tag_id"], name: "index_job_tags_on_job_id_and_tag_id", unique: true
    t.index ["job_id"], name: "index_job_tags_on_job_id"
    t.index ["tag_id"], name: "index_job_tags_on_tag_id"
  end

  create_table "jobs", force: :cascade do |t|
    t.string "agent_provider", null: false
    t.json "approval_evidence", default: {}, null: false
    t.datetime "approved_at"
    t.integer "approved_by_user_id"
    t.string "approved_via"
    t.boolean "auto_merge_enabled", default: false, null: false
    t.datetime "branch_deleted_at"
    t.string "branch_name"
    t.datetime "claimed_at"
    t.integer "claimed_by_user_id"
    t.string "closure_reason"
    t.integer "commits_behind_base"
    t.datetime "created_at", null: false
    t.string "credential_mode", default: "pat", null: false
    t.datetime "dependencies_overridden_at"
    t.integer "dependencies_overridden_by_user_id"
    t.integer "epic_id"
    t.string "epic_title"
    t.integer "external_pr_number"
    t.string "external_ref"
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.integer "fork_review_pr_number"
    t.boolean "github_mergeable"
    t.string "github_mergeable_state"
    t.datetime "grace_period_expires_at"
    t.integer "input_source_id"
    t.json "invalidation_evidence", null: false
    t.text "invalidation_reason"
    t.text "issue_body"
    t.integer "issue_number"
    t.string "issue_title"
    t.string "job_provider_setting", default: "default", null: false
    t.string "kind", default: "issue", null: false
    t.string "landed_sha"
    t.text "landing_failure_reason"
    t.json "landing_queue_blocked_reason"
    t.json "landing_queue_blocker_job_ids"
    t.datetime "landing_queue_cached_at"
    t.json "landing_queue_dependency_edges"
    t.string "landing_queue_entry_key"
    t.integer "landing_queue_entry_position"
    t.integer "landing_queue_position"
    t.json "landing_queue_waiting_job_ids"
    t.string "last_ci_handled_sha"
    t.datetime "last_feedback_addressed_at"
    t.datetime "last_seen_comment_at"
    t.datetime "last_seen_fork_review_comment_at"
    t.integer "linked_chat_id"
    t.string "local_mergeability_base_sha"
    t.datetime "local_mergeability_checked_at"
    t.string "local_mergeability_head_sha"
    t.boolean "local_mergeable"
    t.string "local_mergeable_state"
    t.string "mergeability_base_ref"
    t.string "mergeability_base_sha"
    t.datetime "mergeability_checked_at"
    t.string "mergeability_head_sha"
    t.boolean "needs_attention", default: false, null: false
    t.string "needs_attention_reason"
    t.datetime "needs_attention_since"
    t.integer "owner_user_id"
    t.integer "parent_job_id"
    t.json "pending_epic_reference", null: false
    t.datetime "pr_checks_checked_at"
    t.string "pr_checks_sha"
    t.string "pr_checks_state"
    t.boolean "pr_mergeable"
    t.datetime "pr_mergeable_checked_at"
    t.integer "pr_number"
    t.bigint "pr_repository_id"
    t.string "priority", default: "medium", null: false
    t.integer "repository_id", null: false
    t.integer "scheduled_task_id"
    t.boolean "skip_prepare", default: false, null: false
    t.string "slug"
    t.string "stack_base", default: "auto", null: false
    t.datetime "started_at"
    t.string "state", default: "triaging", null: false
    t.string "system_kind"
    t.bigint "target_repository_id"
    t.boolean "title_pending", default: false, null: false
    t.string "triaging_reason", default: "classifier_pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "validity", default: "valid", null: false
    t.index ["approved_by_user_id"], name: "index_jobs_on_approved_by_user_id"
    t.index ["claimed_at"], name: "index_jobs_on_claimed_at"
    t.index ["claimed_by_user_id"], name: "index_jobs_on_claimed_by_user_id"
    t.index ["closure_reason", "id"], name: "idx_jobs_spending_closure"
    t.index ["credential_mode"], name: "index_jobs_on_credential_mode"
    t.index ["dependencies_overridden_by_user_id"], name: "index_jobs_on_dependencies_overridden_by_user_id"
    t.index ["epic_id"], name: "index_jobs_on_epic_id"
    t.index ["external_pr_number"], name: "index_jobs_on_external_pr_number"
    t.index ["grace_period_expires_at"], name: "index_jobs_on_grace_period_expires_at"
    t.index ["input_source_id"], name: "index_jobs_on_input_source_id"
    t.index ["landing_queue_entry_key"], name: "index_jobs_on_landing_queue_entry_key"
    t.index ["linked_chat_id"], name: "index_jobs_on_linked_chat_id"
    t.index ["needs_attention"], name: "index_jobs_on_needs_attention"
    t.index ["owner_user_id"], name: "index_jobs_on_owner_user_id"
    t.index ["parent_job_id"], name: "index_jobs_on_parent_job_id"
    t.index ["pr_repository_id"], name: "index_jobs_on_pr_repository_id"
    t.index ["repository_id", "issue_number", "state"], name: "index_jobs_on_repository_id_and_issue_number_and_state"
    t.index ["repository_id", "state", "closure_reason", "finished_at"], name: "idx_jobs_repo_state_closure_finished"
    t.index ["repository_id", "state"], name: "index_jobs_on_repository_id_and_state"
    t.index ["repository_id", "system_kind", "state"], name: "index_jobs_on_repository_id_system_kind_state"
    t.index ["repository_id", "updated_at", "id"], name: "idx_jobs_repo_updated_latest"
    t.index ["repository_id"], name: "index_jobs_on_repository_id"
    t.index ["scheduled_task_id"], name: "index_jobs_on_scheduled_task_id"
    t.index ["slug"], name: "index_jobs_on_slug", unique: true
    t.index ["stack_base"], name: "index_jobs_on_stack_base"
    t.index ["state", "approved_at", "id"], name: "index_jobs_on_state_and_approved_at_and_id"
    t.index ["state", "landing_queue_entry_position", "id"], name: "index_jobs_on_state_and_landing_queue_entry_position_and_id"
    t.index ["state", "landing_queue_position", "id"], name: "index_jobs_on_state_and_landing_queue_position_and_id"
    t.index ["target_repository_id"], name: "index_jobs_on_target_repository_id"
    t.index ["triaging_reason"], name: "index_jobs_on_triaging_reason"
    t.index ["user_id", "state", "closure_reason", "finished_at"], name: "idx_jobs_user_state_closure_finished"
    t.index ["user_id"], name: "index_jobs_on_user_id"
    t.index ["validity"], name: "index_jobs_on_validity"
  end

  create_table "local_daemon_sessions", force: :cascade do |t|
    t.string "auth_token", null: false
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.string "daemon_branch"
    t.string "daemon_repo"
    t.datetime "disconnected_at"
    t.datetime "last_heartbeat_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["auth_token"], name: "index_local_daemon_sessions_on_auth_token", unique: true
    t.index ["chat_session_id"], name: "index_local_daemon_sessions_on_chat_session_id"
    t.index ["user_id"], name: "index_local_daemon_sessions_on_user_id"
  end

  create_table "local_tool_calls", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "dispatched_at"
    t.string "error"
    t.integer "local_daemon_session_id", null: false
    t.json "result"
    t.string "state", null: false
    t.json "tool_input"
    t.string "tool_name", null: false
    t.string "tool_use_id", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id"], name: "index_local_tool_calls_on_chat_session_id"
    t.index ["local_daemon_session_id", "state"], name: "index_local_tool_calls_on_local_daemon_session_id_and_state"
    t.index ["local_daemon_session_id"], name: "index_local_tool_calls_on_local_daemon_session_id"
    t.index ["tool_use_id"], name: "index_local_tool_calls_on_tool_use_id"
  end

  create_table "local_tunnel_sessions", force: :cascade do |t|
    t.string "branch"
    t.integer "chat_session_id"
    t.datetime "connected_at"
    t.datetime "created_at", null: false
    t.datetime "disconnected_at"
    t.string "repo_slug"
    t.string "status", default: "connected", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "status"], name: "index_local_tunnel_sessions_on_user_id_and_status"
    t.index ["user_id"], name: "index_local_tunnel_sessions_on_user_id"
  end

  create_table "main_branch_health_checks", force: :cascade do |t|
    t.datetime "checked_at", null: false
    t.json "ci_failed_checks"
    t.string "ci_health", default: "unknown", null: false
    t.datetime "created_at", null: false
    t.json "grader_failed_names"
    t.string "grader_health", default: "unknown", null: false
    t.integer "repository_id", null: false
    t.string "sha", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id"
    t.index ["repository_id", "checked_at"], name: "idx_mbhc_repo_checked_at"
    t.index ["repository_id"], name: "index_main_branch_health_checks_on_repository_id"
    t.index ["workflow_id"], name: "index_main_branch_health_checks_on_workflow_id"
  end

  create_table "main_concern_reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "failing_tests"
    t.integer "job_id", null: false
    t.string "observed_sha"
    t.text "reason", null: false
    t.integer "repository_id", null: false
    t.integer "run_id", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_id", null: false
    t.index ["job_id"], name: "index_main_concern_reports_on_job_id"
    t.index ["repository_id", "created_at"], name: "index_main_concern_reports_on_repository_id_and_created_at"
    t.index ["repository_id"], name: "index_main_concern_reports_on_repository_id"
    t.index ["run_id"], name: "index_main_concern_reports_on_run_id"
    t.index ["workflow_id"], name: "index_main_concern_reports_on_workflow_id"
  end

  create_table "mcp_tool_usages", force: :cascade do |t|
    t.integer "chat_session_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.boolean "error", default: false, null: false
    t.string "error_class"
    t.string "error_message_summary", limit: 512
    t.integer "input_bytes"
    t.integer "job_id"
    t.string "normalized_tool_name", null: false
    t.string "provider"
    t.string "raw_tool_name", null: false
    t.integer "repository_id"
    t.integer "result_bytes"
    t.integer "run_id"
    t.string "server_name"
    t.string "session_id"
    t.datetime "started_at"
    t.string "status", null: false
    t.string "surface", null: false
    t.string "tool_name", null: false
    t.string "tool_use_id"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.integer "workflow_id"
    t.index ["chat_session_id", "tool_use_id"], name: "index_mcp_tool_usages_on_chat_session_id_and_tool_use_id"
    t.index ["chat_session_id"], name: "index_mcp_tool_usages_on_chat_session_id"
    t.index ["job_id"], name: "index_mcp_tool_usages_on_job_id"
    t.index ["repository_id"], name: "index_mcp_tool_usages_on_repository_id"
    t.index ["run_id", "tool_use_id"], name: "index_mcp_tool_usages_on_run_id_and_tool_use_id"
    t.index ["run_id"], name: "index_mcp_tool_usages_on_run_id"
    t.index ["server_name", "normalized_tool_name", "created_at"], name: "idx_mcp_tool_usages_server_tool_window"
    t.index ["surface", "created_at"], name: "index_mcp_tool_usages_on_surface_and_created_at"
    t.index ["surface", "normalized_tool_name", "created_at"], name: "idx_mcp_tool_usages_surface_tool_window"
    t.index ["user_id"], name: "index_mcp_tool_usages_on_user_id"
    t.index ["workflow_id"], name: "index_mcp_tool_usages_on_workflow_id"
  end

  create_table "merge_train_members", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "job_id", null: false
    t.integer "merge_train_id", null: false
    t.integer "position", default: 0, null: false
    t.string "reason", limit: 500
    t.string "state", default: "included", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id"], name: "index_merge_train_members_on_job_id"
    t.index ["merge_train_id", "job_id"], name: "index_merge_train_members_on_merge_train_id_and_job_id", unique: true
    t.index ["merge_train_id", "position"], name: "index_merge_train_members_on_merge_train_id_and_position"
    t.index ["merge_train_id"], name: "index_merge_train_members_on_merge_train_id"
  end

  create_table "merge_trains", force: :cascade do |t|
    t.string "base_branch", null: false
    t.datetime "created_at", null: false
    t.integer "epic_id", null: false
    t.string "failure_reason", limit: 500
    t.datetime "finished_at"
    t.string "integration_branch"
    t.string "integration_sha"
    t.integer "repository_id", null: false
    t.string "state", default: "building", null: false
    t.datetime "updated_at", null: false
    t.index ["epic_id"], name: "index_merge_trains_on_epic_id"
    t.index ["repository_id"], name: "index_merge_trains_on_repository_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "body", null: false
    t.datetime "created_at", null: false
    t.integer "job_id"
    t.string "kind", null: false
    t.string "pr_url"
    t.datetime "read_at"
    t.integer "user_id", null: false
    t.index ["job_id"], name: "index_notifications_on_job_id"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "pr_review_comments", force: :cascade do |t|
    t.boolean "actionable"
    t.datetime "actioned_at"
    t.string "actioned_by"
    t.string "attributed_to"
    t.text "body"
    t.datetime "comment_created_at"
    t.string "comment_kind", null: false
    t.datetime "created_at", null: false
    t.bigint "github_comment_id", null: false
    t.string "github_handle"
    t.datetime "handled_at"
    t.datetime "handling_failed_at"
    t.string "handling_failure_reason"
    t.datetime "handling_started_at"
    t.string "handling_state"
    t.integer "handling_workflow_id"
    t.datetime "ignored_at"
    t.integer "job_id", null: false
    t.string "pr_type", null: false
    t.datetime "updated_at", null: false
    t.index ["actioned_at"], name: "index_pr_review_comments_on_actioned_at"
    t.index ["handling_state"], name: "index_pr_review_comments_on_handling_state"
    t.index ["handling_workflow_id"], name: "index_pr_review_comments_on_handling_workflow_id"
    t.index ["job_id", "pr_type", "comment_kind", "github_comment_id"], name: "index_pr_review_comments_uniqueness", unique: true
    t.index ["job_id"], name: "index_pr_review_comments_on_job_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.string "agent_provider"
    t.boolean "approval_propagates_to_github", default: true
    t.datetime "archived_at"
    t.string "auto_approve_mode", default: "never", null: false
    t.boolean "auto_merge_enabled", default: false, null: false
    t.string "ci_health", default: "unknown", null: false
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.string "epic_dependency_policy", default: "linear", null: false
    t.string "feedback_policy", default: "confirm", null: false
    t.boolean "fork_auto_sync_enabled", default: false, null: false
    t.integer "fork_pr_grace_period_hours", default: 24, null: false
    t.bigint "github_owner_id"
    t.bigint "github_repository_id"
    t.string "grader_health", default: "unknown", null: false
    t.integer "installation_id"
    t.boolean "landing_paused", default: false, null: false
    t.string "last_ci_evaluated_sha"
    t.string "last_graded_sha"
    t.string "last_health_checked_sha"
    t.text "last_poll_error"
    t.datetime "last_poll_started_at"
    t.string "last_poll_status"
    t.boolean "main_branch_health_enabled", default: true, null: false
    t.boolean "main_branch_repair_auto_approve", default: false, null: false
    t.boolean "main_branch_repair_enabled", default: true, null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.boolean "polling_enabled", default: true, null: false
    t.boolean "pr_cost_footer_enabled", default: true, null: false
    t.boolean "prepare_enabled", default: true, null: false
    t.string "review_policy", default: "self", null: false
    t.boolean "treat_grader_timeouts_as_failures", default: false, null: false
    t.string "trigger_label", default: "syrus", null: false
    t.boolean "trust_clean_rebase_grade", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "upstream_default_branch"
    t.string "upstream_name"
    t.string "upstream_owner"
    t.integer "upstream_pr_grace_period_days", default: 7, null: false
    t.bigint "upstream_repository_id"
    t.integer "user_id"
    t.index ["archived_at"], name: "index_repositories_on_archived_at"
    t.index ["github_owner_id"], name: "index_repositories_on_github_owner_id"
    t.index ["github_repository_id"], name: "index_repositories_on_github_repository_id"
    t.index ["installation_id"], name: "index_repositories_on_installation_id"
    t.index ["landing_paused"], name: "index_repositories_on_landing_paused"
    t.index ["owner", "name"], name: "index_repositories_on_owner_and_name", unique: true
    t.index ["upstream_repository_id"], name: "index_repositories_on_upstream_repository_id"
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "repository_final_approvers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "repository_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["repository_id", "user_id"], name: "index_repo_final_approvers_on_repository_and_user", unique: true
    t.index ["repository_id"], name: "index_repository_final_approvers_on_repository_id"
    t.index ["user_id"], name: "index_repository_final_approvers_on_user_id"
  end

  create_table "repository_memberships", force: :cascade do |t|
    t.string "agent_provider"
    t.datetime "created_at", null: false
    t.bigint "installation_id"
    t.integer "repository_id", null: false
    t.string "role", default: "owner", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["installation_id"], name: "index_repository_memberships_on_installation_id"
    t.index ["repository_id", "user_id"], name: "index_repository_memberships_on_repository_id_and_user_id", unique: true
    t.index ["repository_id"], name: "index_repository_memberships_on_repository_id"
    t.index ["user_id"], name: "index_repository_memberships_on_user_id"
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

  create_table "run_failure_classifications", force: :cascade do |t|
    t.string "classification", null: false
    t.datetime "classified_at"
    t.text "classifier_inputs"
    t.decimal "confidence", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.text "diagnostic_summary"
    t.text "reason"
    t.boolean "retryable", null: false
    t.integer "run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["classification"], name: "index_run_failure_classifications_on_classification"
    t.index ["classified_at"], name: "index_run_failure_classifications_on_classified_at"
    t.index ["retryable"], name: "index_run_failure_classifications_on_retryable"
    t.index ["run_id"], name: "index_run_failure_classifications_on_run_id", unique: true
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
    t.index ["run_id", "created_at", "id"], name: "idx_run_health_snapshots_run_created"
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
    t.string "base_sha"
    t.bigint "cache_creation_input_tokens"
    t.bigint "cache_read_input_tokens"
    t.decimal "cost_usd", precision: 12, scale: 6
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "head_sha"
    t.bigint "input_tokens"
    t.integer "iteration", default: 1, null: false
    t.integer "job_id", null: false
    t.datetime "last_heartbeat_at"
    t.string "live_session_id"
    t.bigint "output_tokens"
    t.string "parent_session_id"
    t.text "prompt"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.text "step_agent_diff", limit: 16777215
    t.integer "step_id"
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["agent_provider", "cost_usd"], name: "idx_runs_spending_provider_cost"
    t.index ["agent_provider", "created_at", "cost_usd"], name: "idx_runs_spending_provider_window"
    t.index ["cost_usd", "created_at"], name: "idx_runs_spending_top_cost"
    t.index ["created_at", "cost_usd"], name: "index_runs_on_created_at_and_cost_usd"
    t.index ["created_at", "job_id", "cost_usd"], name: "idx_runs_spending_window_jobs"
    t.index ["job_id", "created_at", "id"], name: "idx_runs_job_latest"
    t.index ["job_id", "state"], name: "index_runs_on_job_id_and_state"
    t.index ["job_id"], name: "index_runs_on_job_id"
    t.index ["parent_session_id"], name: "index_runs_on_parent_session_id"
    t.index ["state", "job_id", "updated_at"], name: "idx_runs_state_job_updated"
    t.index ["state", "last_heartbeat_at"], name: "index_runs_on_state_and_last_heartbeat_at"
    t.index ["step_id", "created_at", "id"], name: "idx_runs_step_created"
    t.index ["step_id"], name: "index_runs_on_step_id"
    t.index ["user_id", "agent_provider", "finished_at", "updated_at", "id"], name: "idx_runs_provider_latest_finished"
    t.index ["user_id", "created_at", "cost_usd"], name: "idx_runs_spending_user_window"
    t.index ["user_id"], name: "index_runs_on_user_id"
  end

  create_table "scheduled_chat_messages", force: :cascade do |t|
    t.text "body", null: false
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "fire_at", null: false
    t.datetime "sent_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["chat_session_id"], name: "index_scheduled_chat_messages_on_chat_session_id"
    t.index ["sent_at", "fire_at"], name: "index_scheduled_chat_messages_on_sent_at_and_fire_at"
    t.index ["user_id"], name: "index_scheduled_chat_messages_on_user_id"
  end

  create_table "scheduled_tasks", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "auto_approve_mode", default: "never", null: false
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

  create_table "smart_folders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "filter", default: {}, null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.string "subject_type", limit: 16, default: "job", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["kind"], name: "index_smart_folders_on_kind"
    t.index ["subject_type", "user_id"], name: "index_smart_folders_on_subject_type_and_user_id"
    t.index ["user_id", "name", "subject_type"], name: "index_smart_folders_on_user_id_name_subject_type", unique: true
    t.index ["user_id", "position"], name: "index_smart_folders_on_user_id_and_position"
    t.index ["user_id"], name: "index_smart_folders_on_user_id"
  end

  create_table "spawned_processes", force: :cascade do |t|
    t.string "command", limit: 4096, null: false
    t.datetime "created_at", null: false
    t.integer "exit_status"
    t.datetime "finished_at"
    t.string "hostname", limit: 255, null: false
    t.datetime "kill_requested_at"
    t.integer "kill_requested_by_user_id"
    t.string "kind", limit: 32, null: false
    t.datetime "last_chunk_at"
    t.string "outcome", limit: 32
    t.integer "pgid"
    t.integer "pid"
    t.integer "run_id"
    t.integer "silent_timeout_s"
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.integer "wall_timeout_s"
    t.string "workdir", limit: 4096
    t.integer "workflow_id"
    t.index ["finished_at", "hostname", "pid", "last_chunk_at"], name: "idx_spawned_processes_active_host_pid"
    t.index ["finished_at", "last_chunk_at"], name: "idx_spawned_processes_active"
    t.index ["finished_at"], name: "index_spawned_processes_on_finished_at"
    t.index ["hostname"], name: "index_spawned_processes_on_hostname"
    t.index ["kill_requested_by_user_id"], name: "index_spawned_processes_on_kill_requested_by_user_id"
    t.index ["kind", "workdir", "finished_at"], name: "idx_spawned_processes_kind_workdir_active"
    t.index ["kind"], name: "index_spawned_processes_on_kind"
    t.index ["run_id", "finished_at", "started_at", "id"], name: "idx_spawned_processes_run_active_started"
    t.index ["run_id"], name: "index_spawned_processes_on_run_id"
    t.index ["workflow_id"], name: "index_spawned_processes_on_workflow_id"
  end

  create_table "state_transitions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_name"
    t.string "from_state", null: false
    t.json "metadata"
    t.bigint "run_id"
    t.string "source", default: "aasm", null: false
    t.integer "subject_id", null: false
    t.string "subject_type", null: false
    t.string "to_state", null: false
    t.bigint "user_id"
    t.index ["created_at"], name: "index_state_transitions_on_created_at"
    t.index ["run_id"], name: "index_state_transitions_on_run_id"
    t.index ["subject_type", "subject_id", "created_at"], name: "idx_state_transitions_on_subject_created"
    t.index ["subject_type", "subject_id"], name: "index_state_transitions_on_subject"
    t.index ["user_id"], name: "index_state_transitions_on_user_id"
  end

  create_table "steps", force: :cascade do |t|
    t.string "cancellation_reason"
    t.datetime "created_at", null: false
    t.json "details", null: false
    t.datetime "finished_at"
    t.integer "iteration", default: 1, null: false
    t.string "kind", null: false
    t.string "loop_id"
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

  create_table "tags", force: :cascade do |t|
    t.string "color", default: "gray", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "team_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["team_id"], name: "index_tags_on_team_id"
    t.index ["user_id", "name"], name: "index_tags_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_tags_on_user_id"
  end

  create_table "terminal_sessions", force: :cascade do |t|
    t.string "auth_token", null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "name", null: false
    t.string "outcome"
    t.string "relay_address"
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "workflow_id"
    t.string "working_directory", null: false
    t.index ["finished_at"], name: "index_terminal_sessions_on_finished_at"
    t.index ["user_id"], name: "index_terminal_sessions_on_user_id"
    t.index ["workflow_id"], name: "index_terminal_sessions_on_workflow_id"
  end

  create_table "test_cases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "failure_backtrace"
    t.text "failure_message"
    t.string "file_path"
    t.string "name", null: false
    t.text "output"
    t.bigint "repository_id", null: false
    t.string "status", limit: 32, null: false
    t.string "suite_name", null: false
    t.bigint "test_run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["repository_id", "suite_name", "name"], name: "idx_test_cases_repo_suite_name"
    t.index ["repository_id"], name: "index_test_cases_on_repository_id"
    t.index ["test_run_id", "status"], name: "idx_test_cases_run_status"
    t.index ["test_run_id"], name: "index_test_cases_on_test_run_id"
  end

  create_table "test_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.integer "error_count", default: 0, null: false
    t.integer "failed_count", default: 0, null: false
    t.string "grader_name", limit: 128, null: false
    t.integer "passed_count", default: 0, null: false
    t.bigint "repository_id", null: false
    t.bigint "run_id", null: false
    t.integer "skipped_count", default: 0, null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["repository_id"], name: "index_test_runs_on_repository_id"
    t.index ["run_id", "grader_name"], name: "idx_test_runs_run_grader_unique", unique: true
    t.index ["run_id"], name: "index_test_runs_on_run_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.integer "agent_max_turns", default: 200, null: false
    t.string "agent_provider", default: "claude", null: false
    t.text "api_token"
    t.string "auto_approve_mode", default: "never", null: false
    t.string "avatar_url"
    t.string "chat_provider"
    t.text "claude_oauth_token"
    t.text "codex_api_key"
    t.text "codex_auth_json"
    t.string "codex_auth_mode", default: "api_key", null: false
    t.datetime "codex_usage_observed_at"
    t.json "codex_usage_snapshot"
    t.string "codex_usage_status"
    t.datetime "created_at", null: false
    t.json "dashboard_preferences"
    t.string "email_address", null: false
    t.integer "epic_reopen_window", default: 30, null: false
    t.string "first_name"
    t.text "gemini_api_key"
    t.datetime "gh_api_blocked_at"
    t.text "gh_api_blocked_reason"
    t.integer "gh_rate_limit_limit"
    t.datetime "gh_rate_limit_observed_at"
    t.integer "gh_rate_limit_remaining"
    t.datetime "gh_rate_limit_reset_at"
    t.string "gh_rate_limit_resource", limit: 32
    t.string "github_handle"
    t.text "github_token"
    t.boolean "landing_paused", default: false, null: false
    t.string "last_name"
    t.string "locale", null: false
    t.string "name"
    t.json "notification_preferences", null: false
    t.string "password_digest", null: false
    t.text "profile_bio"
    t.string "profile_company"
    t.string "profile_location"
    t.string "profile_website"
    t.string "role", default: "developer", null: false
    t.boolean "scheduling_paused", default: false, null: false
    t.string "theme", default: "light", null: false
    t.json "ui_preferences", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["landing_paused"], name: "index_users_on_landing_paused"
  end

  create_table "whiteboard_snapshots", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.integer "element_count", null: false
    t.string "name"
    t.json "scene_json", null: false
    t.string "snapshot_kind", null: false
    t.index ["chat_session_id"], name: "index_whiteboard_snapshots_on_chat_session_id"
  end

  create_table "whiteboards", force: :cascade do |t|
    t.integer "chat_session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_edited_at"
    t.json "scene_json", default: {"elements" => []}, null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["chat_session_id"], name: "index_whiteboards_on_chat_session_id", unique: true
  end

  create_table "worker_host_health_samples", force: :cascade do |t|
    t.float "cpu_pressure_full"
    t.float "cpu_pressure_some"
    t.float "cpu_used_percent"
    t.datetime "created_at", null: false
    t.bigint "data_root_available_bytes"
    t.bigint "data_root_total_bytes"
    t.float "data_root_used_percent"
    t.string "hostname", null: false
    t.float "io_pressure_full"
    t.float "io_pressure_some"
    t.float "load_15m"
    t.float "load_1m"
    t.float "load_5m"
    t.bigint "memory_available_bytes"
    t.bigint "memory_total_bytes"
    t.float "memory_used_percent"
    t.datetime "observed_at", null: false
    t.json "raw_metrics", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["hostname", "role", "observed_at"], name: "idx_worker_host_health_samples_host_role_observed", unique: true
    t.index ["observed_at"], name: "index_worker_host_health_samples_on_observed_at"
  end

  create_table "workflows", force: :cascade do |t|
    t.string "agent_provider", default: "claude", null: false
    t.text "artifacts", limit: 16777215
    t.text "chain_template"
    t.datetime "cleaned_up_at"
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.string "failure_reason"
    t.datetime "finished_at"
    t.integer "job_id", null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "worker_hostname"
    t.index ["cleaned_up_at"], name: "index_workflows_on_cleaned_up_at"
    t.index ["job_id", "created_at"], name: "index_workflows_on_job_id_and_created_at"
    t.index ["job_id", "finished_at", "id"], name: "idx_workflows_job_finished_latest"
    t.index ["job_id"], name: "index_workflows_on_job_id"
    t.index ["state", "created_at", "id"], name: "idx_workflows_state_created_at"
    t.index ["state", "started_at", "id"], name: "idx_workflows_state_started_at"
    t.index ["user_id"], name: "index_workflows_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "admin_actions", "users"
  add_foreign_key "auto_retry_attempts", "jobs"
  add_foreign_key "auto_retry_attempts", "runs"
  add_foreign_key "auto_retry_attempts", "workflows"
  add_foreign_key "chat_agent_questions", "chat_sessions"
  add_foreign_key "chat_attachments", "chat_sessions"
  add_foreign_key "chat_bookmarks", "chat_messages"
  add_foreign_key "chat_memories", "users"
  add_foreign_key "chat_memories", "users", column: "deleted_by_user_id"
  add_foreign_key "chat_memory_audit_events", "chat_memories"
  add_foreign_key "chat_memory_audit_events", "runs", column: "actor_run_id"
  add_foreign_key "chat_memory_audit_events", "users", column: "actor_user_id"
  add_foreign_key "chat_messages", "chat_pending_actions", column: "pending_action_id"
  add_foreign_key "chat_messages", "chat_proposals", column: "proposal_id"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_pending_actions", "chat_sessions"
  add_foreign_key "chat_pending_actions", "repositories"
  add_foreign_key "chat_pending_actions", "users"
  add_foreign_key "chat_proposal_dependencies", "chat_proposals", column: "depends_on_id"
  add_foreign_key "chat_proposal_dependencies", "chat_proposals", column: "proposal_id"
  add_foreign_key "chat_proposals", "chat_proposals", column: "parent_proposal_id"
  add_foreign_key "chat_proposals", "chat_sessions"
  add_foreign_key "chat_proposals", "epics"
  add_foreign_key "chat_proposals", "epics", column: "target_epic_id"
  add_foreign_key "chat_proposals", "jobs"
  add_foreign_key "chat_proposals", "repositories"
  add_foreign_key "chat_queued_messages", "chat_sessions"
  add_foreign_key "chat_scratchpad_items", "chat_sessions"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "chat_video_walkthroughs", "chat_sessions"
  add_foreign_key "chat_video_walkthroughs", "users"
  add_foreign_key "chat_wakeups", "chat_sessions"
  add_foreign_key "chat_wakeups", "users"
  add_foreign_key "chat_whiteboards", "chat_sessions"
  add_foreign_key "claude_sessions", "runs"
  add_foreign_key "coverage_snapshots", "jobs"
  add_foreign_key "coverage_snapshots", "repositories"
  add_foreign_key "coverage_snapshots", "workflows"
  add_foreign_key "cron_templates", "users"
  add_foreign_key "documents", "users"
  add_foreign_key "epic_dependencies", "epics"
  add_foreign_key "epic_dependencies", "epics", column: "depends_on_epic_id"
  add_foreign_key "epic_dependencies", "jobs", column: "depends_on_job_id"
  add_foreign_key "epic_versions", "epics"
  add_foreign_key "epic_versions", "users"
  add_foreign_key "epics", "repositories"
  add_foreign_key "epics", "users"
  add_foreign_key "epics", "users", column: "owner_id"
  add_foreign_key "epics", "users", column: "owner_user_id"
  add_foreign_key "filter_usages", "users"
  add_foreign_key "grader_conclusions", "jobs"
  add_foreign_key "grader_conclusions", "repositories"
  add_foreign_key "grader_conclusions", "runs"
  add_foreign_key "grader_conclusions", "steps"
  add_foreign_key "grader_conclusions", "workflows"
  add_foreign_key "input_sources", "repositories"
  add_foreign_key "input_sources", "users"
  add_foreign_key "insight_schedule_configs", "repositories"
  add_foreign_key "insight_suggestions", "jobs"
  add_foreign_key "insight_suggestions", "jobs", column: "created_job_id"
  add_foreign_key "insight_suggestions", "repositories"
  add_foreign_key "installations", "users"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "job_approvals", "jobs"
  add_foreign_key "job_approvals", "users"
  add_foreign_key "job_dependencies", "chat_proposals", column: "unresolved_chat_proposal_id"
  add_foreign_key "job_dependencies", "epics", column: "depends_on_epic_id"
  add_foreign_key "job_dependencies", "jobs"
  add_foreign_key "job_dependencies", "jobs", column: "depends_on_job_id"
  add_foreign_key "job_dependencies", "users", column: "created_by_user_id"
  add_foreign_key "job_deployment_stage_statuses", "jobs"
  add_foreign_key "job_logs", "runs"
  add_foreign_key "job_pins", "jobs"
  add_foreign_key "job_pins", "users"
  add_foreign_key "jobs", "chat_sessions", column: "linked_chat_id"
  add_foreign_key "jobs", "epics"
  add_foreign_key "jobs", "input_sources"
  add_foreign_key "jobs", "jobs", column: "parent_job_id"
  add_foreign_key "jobs", "repositories"
  add_foreign_key "jobs", "repositories", column: "pr_repository_id"
  add_foreign_key "jobs", "repositories", column: "target_repository_id"
  add_foreign_key "jobs", "scheduled_tasks"
  add_foreign_key "jobs", "users"
  add_foreign_key "jobs", "users", column: "approved_by_user_id"
  add_foreign_key "jobs", "users", column: "claimed_by_user_id"
  add_foreign_key "jobs", "users", column: "dependencies_overridden_by_user_id"
  add_foreign_key "jobs", "users", column: "owner_user_id"
  add_foreign_key "local_daemon_sessions", "chat_sessions"
  add_foreign_key "local_daemon_sessions", "users"
  add_foreign_key "local_tool_calls", "chat_sessions"
  add_foreign_key "local_tool_calls", "local_daemon_sessions"
  add_foreign_key "local_tunnel_sessions", "users"
  add_foreign_key "main_branch_health_checks", "repositories"
  add_foreign_key "main_branch_health_checks", "workflows"
  add_foreign_key "main_concern_reports", "jobs"
  add_foreign_key "main_concern_reports", "repositories"
  add_foreign_key "main_concern_reports", "runs"
  add_foreign_key "main_concern_reports", "workflows"
  add_foreign_key "mcp_tool_usages", "chat_sessions"
  add_foreign_key "mcp_tool_usages", "jobs"
  add_foreign_key "mcp_tool_usages", "repositories"
  add_foreign_key "mcp_tool_usages", "runs"
  add_foreign_key "mcp_tool_usages", "users"
  add_foreign_key "mcp_tool_usages", "workflows"
  add_foreign_key "merge_train_members", "jobs"
  add_foreign_key "merge_train_members", "merge_trains"
  add_foreign_key "merge_trains", "epics"
  add_foreign_key "merge_trains", "repositories"
  add_foreign_key "notifications", "jobs"
  add_foreign_key "notifications", "users"
  add_foreign_key "pr_review_comments", "jobs"
  add_foreign_key "pr_review_comments", "workflows", column: "handling_workflow_id"
  add_foreign_key "repositories", "installations"
  add_foreign_key "repositories", "repositories", column: "upstream_repository_id"
  add_foreign_key "repositories", "users"
  add_foreign_key "repository_final_approvers", "repositories"
  add_foreign_key "repository_final_approvers", "users"
  add_foreign_key "repository_memberships", "installations", on_delete: :nullify
  add_foreign_key "repository_memberships", "repositories"
  add_foreign_key "repository_memberships", "users"
  add_foreign_key "run_diagnostics", "runs"
  add_foreign_key "run_failure_classifications", "runs"
  add_foreign_key "run_health_snapshots", "runs"
  add_foreign_key "runs", "jobs"
  add_foreign_key "runs", "steps"
  add_foreign_key "runs", "users"
  add_foreign_key "scheduled_chat_messages", "chat_sessions"
  add_foreign_key "scheduled_chat_messages", "users"
  add_foreign_key "scheduled_tasks", "cron_templates"
  add_foreign_key "scheduled_tasks", "repositories"
  add_foreign_key "scheduled_tasks", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "smart_folders", "users"
  add_foreign_key "spawned_processes", "runs"
  add_foreign_key "spawned_processes", "users", column: "kill_requested_by_user_id"
  add_foreign_key "spawned_processes", "workflows"
  add_foreign_key "steps", "steps", column: "next_step_id"
  add_foreign_key "steps", "workflows"
  add_foreign_key "terminal_sessions", "users"
  add_foreign_key "terminal_sessions", "workflows"
  add_foreign_key "test_cases", "repositories"
  add_foreign_key "test_cases", "test_runs"
  add_foreign_key "test_runs", "repositories"
  add_foreign_key "test_runs", "runs"
  add_foreign_key "whiteboard_snapshots", "chat_sessions"
  add_foreign_key "whiteboards", "chat_sessions"
  add_foreign_key "workflows", "jobs"
  add_foreign_key "workflows", "users"
end
