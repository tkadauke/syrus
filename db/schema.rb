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

ActiveRecord::Schema[8.1].define(version: 2026_05_03_021334) do
  create_table "app_settings", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "max_job_failures", default: 3, null: false
    t.boolean "signups_open", default: false, null: false
    t.datetime "updated_at", null: false
  end

  create_table "claude_sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "run_id", null: false
    t.string "session_id", null: false
    t.text "transcript_jsonl", size: :long
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_claude_sessions_on_created_at"
    t.index ["run_id"], name: "index_claude_sessions_on_run_id", unique: true
  end

  create_table "invitations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "expires_at", null: false
    t.bigint "invited_by_id", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_invitations_on_email_address"
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "job_logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "chunk", null: false
    t.datetime "created_at", null: false
    t.bigint "run_id", null: false
    t.integer "sequence", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "sequence"], name: "index_job_logs_on_run_id_and_sequence", unique: true
    t.index ["run_id"], name: "index_job_logs_on_run_id"
  end

  create_table "jobs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "branch_name"
    t.string "closure_reason"
    t.datetime "created_at", null: false
    t.integer "external_pr_number"
    t.integer "failure_count", default: 0, null: false
    t.datetime "finished_at"
    t.integer "issue_number", null: false
    t.string "last_ci_handled_sha"
    t.datetime "last_seen_comment_at"
    t.boolean "pr_mergeable"
    t.datetime "pr_mergeable_checked_at"
    t.integer "pr_number"
    t.bigint "repository_id", null: false
    t.datetime "started_at"
    t.string "state", default: "open", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["external_pr_number"], name: "index_jobs_on_external_pr_number"
    t.index ["repository_id", "issue_number", "state"], name: "index_jobs_on_repository_id_and_issue_number_and_state"
    t.index ["repository_id", "state"], name: "index_jobs_on_repository_id_and_state"
    t.index ["repository_id"], name: "index_jobs_on_repository_id"
    t.index ["user_id"], name: "index_jobs_on_user_id"
  end

  create_table "repositories", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "default_branch", default: "main", null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.boolean "polling_enabled", default: true, null: false
    t.string "trigger_label", default: "syrus", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["archived_at"], name: "index_repositories_on_archived_at"
    t.index ["user_id", "owner", "name"], name: "index_repositories_on_user_id_and_owner_and_name", unique: true
    t.index ["user_id"], name: "index_repositories_on_user_id"
  end

  create_table "runs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "agent_diff"
    t.string "agent_outcome"
    t.text "agent_pr_body"
    t.string "agent_pr_title"
    t.text "agent_summary"
    t.integer "agent_turns"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "head_sha"
    t.bigint "job_id", null: false
    t.datetime "last_heartbeat_at"
    t.string "parent_session_id"
    t.text "prompt"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.string "trigger_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["job_id", "state"], name: "index_runs_on_job_id_and_state"
    t.index ["job_id"], name: "index_runs_on_job_id"
    t.index ["parent_session_id"], name: "index_runs_on_parent_session_id"
    t.index ["state", "last_heartbeat_at"], name: "index_runs_on_state_and_last_heartbeat_at"
  end

  create_table "sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.string "claude_oauth_token"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "github_token"
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "claude_sessions", "runs"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "job_logs", "runs"
  add_foreign_key "jobs", "repositories"
  add_foreign_key "jobs", "users"
  add_foreign_key "repositories", "users"
  add_foreign_key "runs", "jobs"
  add_foreign_key "sessions", "users"
end
