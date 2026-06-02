Rails.application.routes.draw do
  get "session/new", to: "spa#show", as: :new_session
  resource :session, only: %i[ create destroy ]
  get "passwords/new", to: "spa#show", as: :new_password
  post "passwords", to: "passwords#create", as: :passwords
  get "passwords/:token/edit", to: "spa#show", as: :edit_password
  match "passwords/:token", to: "passwords#update", as: :password, via: %i[ patch put ]
  get "users/new", to: "spa#show", as: :new_user
  resources :users, only: %i[ create ]

  get "credentials/edit", to: "spa#show", as: :edit_credentials
  get "setup", to: "spa#show", as: :setup

  # Admin REST API. Token-based auth (per-user), JSON only.
  # See docs/plans/complete/admin-diagnostics.md for the endpoint plan.
  namespace :api do
    namespace :v1 do
      namespace :app do
        get "bootstrap", to: "bootstrap#show"
        get "setup", to: "setup#show"
        get "auth/signup", to: "auth#signup"
        post "auth/session", to: "auth#create_session"
        post "auth/users", to: "auth#create_user"
        post "auth/passwords", to: "auth#create_password"
        patch "auth/passwords/:token", to: "auth#update_password"
        post "bug_reports", to: "bug_reports#create"
        resources :tags, only: %i[ index create update destroy ]
        resources :smart_folders, only: %i[ index create update destroy ]
        resources :cron_templates, only: %i[ index show create update destroy ]
        resource :credentials, only: %i[ show update ] do
          post :clear_credential
          post :rotate_api_token
          delete :revoke_api_token
          resources :documents, only: %i[ index create destroy ], controller: "credentials/documents"
        end
        get "jobs/new", to: "direct_jobs#new"
        post "jobs", to: "direct_jobs#create"
        get "jobs/:id/source", to: "jobs#source", constraints: { id: /\d+/ }
        get "jobs/:id/timeline", to: "jobs#timeline", constraints: { id: /\d+/ }
        get "jobs/:job_id/runs/:run_id/artifacts", to: "jobs#run_artifacts", constraints: { job_id: /\d+/, run_id: /\d+/ }
        get "jobs/:job_id/runs/:run_id/grade_log", to: "jobs#grade_log", constraints: { job_id: /\d+/, run_id: /\d+/ }
        get "jobs/:id", to: "jobs#show", constraints: { id: /\d+/ }
        post "jobs/:job_id/pin", to: "job_pins#create", constraints: { job_id: /\d+/ }
        delete "jobs/:job_id/pin", to: "job_pins#destroy", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/attachments", to: "job_attachments#create", constraints: { job_id: /\d+/ }
        delete "jobs/:job_id/attachments/:id", to: "job_attachments#destroy", constraints: { job_id: /\d+/, id: /\d+/ }
        post "jobs/:job_id/tags", to: "job_metadata#add_tag", constraints: { job_id: /\d+/ }
        delete "jobs/:job_id/tags/:tag_id", to: "job_metadata#remove_tag", constraints: { job_id: /\d+/, tag_id: /\d+/ }
        post "jobs/:job_id/dependencies", to: "job_metadata#add_dependency", constraints: { job_id: /\d+/ }
        delete "jobs/:job_id/dependencies/:dependency_id", to: "job_metadata#remove_dependency", constraints: { job_id: /\d+/, dependency_id: /\d+/ }
        post "jobs/:job_id/dependencies/override", to: "job_metadata#override_dependencies", constraints: { job_id: /\d+/ }
        patch "jobs/:job_id/stack_base", to: "job_metadata#stack_base", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/mark_valid", to: "job_metadata#mark_valid", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/start", to: "job_lifecycle#start", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/run_again", to: "job_lifecycle#run_again", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/restart", to: "job_lifecycle#restart", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/cancel", to: "job_lifecycle#cancel", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/approve", to: "job_lifecycle#approve", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/unapprove", to: "job_lifecycle#unapprove", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/reopen", to: "job_lifecycle#reopen", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/poll_feedback", to: "job_run_commands#poll_feedback", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/rebase", to: "job_run_commands#rebase", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/check_mergeability", to: "job_run_commands#check_mergeability", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/resume", to: "job_run_commands#resume", constraints: { job_id: /\d+/ }
        post "jobs/:job_id/runs/:run_id/stop", to: "job_run_commands#stop_run", constraints: { job_id: /\d+/, run_id: /\d+/ }
        post "jobs/:job_id/runs/:run_id/diagnose", to: "job_run_commands#diagnose", constraints: { job_id: /\d+/, run_id: /\d+/ }
        post "jobs/:job_id/workflows/:workflow_id/retry_step", to: "job_run_commands#retry_step", constraints: { job_id: /\d+/, workflow_id: /\d+/ }
        post "jobs/:job_id/workflows/:workflow_id/push_commits", to: "job_run_commands#push_commits", constraints: { job_id: /\d+/, workflow_id: /\d+/ }
        get "epics/new", to: "epics#new"
        get "epics/:id", to: "epics#show", constraints: { id: /\d+/ }
        get "epics/:id/edit", to: "epics#edit", constraints: { id: /\d+/ }
        post "epics", to: "epics#create"
        patch "epics/:id", to: "epics#update", constraints: { id: /\d+/ }
        patch "epics/:id/archive", to: "epics#archive", constraints: { id: /\d+/ }
        patch "epics/:id/state", to: "epics#update_state", constraints: { id: /\d+/ }
        get "filters/fk_options", to: "filters#fk_options"
        get "dashboard", to: "dashboard#show"
        patch "dashboard/preferences", to: "dashboard#preferences"
        post "dashboard/landing_pause", to: "dashboard#landing_pause"
        post "dashboard/jobs/bulk", to: "dashboard#bulk_jobs"
        patch "dashboard/epics/:id/auto_approval", to: "dashboard#epic_auto_approval", constraints: { id: /\d+/ }
        get "chats/new", to: "chats#new"
        post "chats", to: "chats#create"
        get "chats/:id", to: "chats#show", constraints: { id: /\d+/ }
        get "chats/:id/messages", to: "chats#messages", constraints: { id: /\d+/ }
        get "chats/:id/whiteboard", to: "chat_whiteboards#show", constraints: { id: /\d+/ }
        patch "chats/:id/whiteboard", to: "chat_whiteboards#update", constraints: { id: /\d+/ }
        post "chats/:id/message", to: "chats#message", constraints: { id: /\d+/ }
        post "chats/:id/stop", to: "chats#stop", constraints: { id: /\d+/ }
        post "chats/:id/bookmarks", to: "chats#create_bookmark", constraints: { id: /\d+/ }
        post "chats/:id/attachments", to: "chats#add_attachment", constraints: { id: /\d+/ }
        delete "chats/:id/attachments/:attachment_id", to: "chats#destroy_attachment", constraints: { id: /\d+/, attachment_id: /\d+/ }
        post "chats/:id/proposals/:proposal_id/confirm", to: "chats#confirm_proposal", constraints: { id: /\d+/, proposal_id: /\d+/ }
        post "chats/:id/proposals/:proposal_id/reject", to: "chats#reject_proposal", constraints: { id: /\d+/, proposal_id: /\d+/ }
        post "chats/:id/pending_actions/:pending_action_id/confirm", to: "chats#confirm_pending_action", constraints: { id: /\d+/, pending_action_id: /\d+/ }
        delete "chats/:id/pending_actions/:pending_action_id", to: "chats#destroy_pending_action", constraints: { id: /\d+/, pending_action_id: /\d+/ }
        get "repositories/new", to: "repositories#new"
        get "repositories/:id/edit", to: "repositories#edit", constraints: { id: /\d+/ }
        get "repositories/owners", to: "repositories#owners"
        get "repositories/repos", to: "repositories#repos"
        get "repositories/branches", to: "repositories#branches"
        resources :repositories, only: %i[ index show create update ] do
          member do
            get "issues", to: "repositories#issues"
            post "issues/comment", to: "repositories#comment_issue"
            post "issues/close", to: "repositories#close_issue"
            post "issues/delegate", to: "repositories#delegate_issue"
            post "issues/bulk", to: "repositories#bulk_issues"
            post :poll
            post :archive
            post :unarchive
            post :retry_failed_jobs
          end
        end
        post "repositories/:id/notes", to: "repositories#create_note", constraints: { id: /\d+/ }
        delete "repositories/:repository_id/notes/:id", to: "repositories#destroy_note", constraints: { repository_id: /\d+/, id: /\d+/ }
        get "repositories/:repository_id/documents", to: "repository_documents#index"
        post "repositories/:repository_id/documents", to: "repository_documents#create"
        delete "repository_documents/:id", to: "repository_documents#destroy"
        get "repositories/:repository_id/scheduled_tasks/new", to: "scheduled_tasks#new"
        get "repositories/:repository_id/scheduled_tasks", to: "scheduled_tasks#repository_index"
        post "repositories/:repository_id/scheduled_tasks", to: "scheduled_tasks#create"
        patch "repositories/:repository_id/scheduled_tasks/:id", to: "scheduled_tasks#repository_update"
        delete "repositories/:repository_id/scheduled_tasks/:id", to: "scheduled_tasks#repository_destroy"
        resources :scheduled_tasks, only: %i[ index show update destroy ] do
          member do
            post :pause
            post :resume
            post :fire_now
          end
        end

        namespace :admin do
          get "overview", to: "overview#show"
          get "queue/:tab", to: "queue#show", as: :queue, constraints: { tab: /active|pending|failed|recurring|workers/ }
          post "queue/reap_stale_runs", to: "queue#reap_stale_runs"
          get "stuck", to: "stuck#index"
          get "github_app/register", to: "github_app#register"
          get "github_app/confirm", to: "github_app#confirm"
          resources :processes, only: %i[ index show ], controller: "spawned_processes" do
            member do
              post :kill
            end
          end
          get "runs/:run_id/transcript", to: "transcripts#show"
          resources :users, only: %i[ index show ] do
            member do
              post :pause_scheduling
              post :unpause_scheduling
            end
          end
          get  "console", to: "console#show"
          post "console/pause_polling", to: "console#pause_polling"
          post "console/unpause_polling", to: "console#unpause_polling"
          post "console/pause_runs", to: "console#pause_runs"
          post "console/unpause_runs", to: "console#unpause_runs"
          post "console/clear_github_cache", to: "console#clear_github_cache"
          get "installations", to: "installations#index"
          post "installations/refresh", to: "installations#refresh"
          resources :invitations, only: %i[ index create destroy ]
          get "settings", to: "settings#show"
          patch "settings", to: "settings#update"
          post "settings/clear_secret", to: "settings#clear_secret"
        end
      end

      namespace :admin do
        # `#show` returns the deep-nested Job state (workflows + steps
        # + runs + diagnostics + claude_session metadata). `#index`
        # is a compact list — supports `?pr_number=`, `?issue_number=`,
        # `?repo=owner/name`, `?state=` to find a Job from external
        # references (a GH PR url, an issue link, etc.) so the agent
        # doesn't have to know the Syrus internal Job ID up front.
        resources :jobs, only: %i[ show index ]

        # Epic read API. `#index` is compact (filter via ?state=,
        # ?repo=owner/name, ?user=, ?has_unfinished_children=true);
        # `#show` returns the full epic with child jobs + dependency
        # edges + pending dependency refs.
        resources :epics, only: %i[ show index ]

        # Compact list of Runs for cross-Job investigations
        # ("show me everything that failed in the last hour"
        # without walking each Job's response). Filters via
        # ?state, ?since, ?trigger_kind, ?job_id; default ordering
        # is most-recently-finished first. Pagination via ?page +
        # ?per (max 100).
        get "runs", to: "runs#index"

        # Transcripts. Paginated event stream via ?page= + ?per=,
        # plus a raw-JSONL pass-through.
        get "runs/:run_id/transcript",     to: "transcripts#show"
        get "runs/:run_id/transcript/raw", to: "transcripts#raw"

        # Queue introspection for external admin API clients.
        get  "queue/active",              to: "queue#active"
        get  "queue/pending",             to: "queue#pending"
        get  "queue/failed",              to: "queue#failed"
        get  "queue/recurring",           to: "queue#recurring"
        get  "queue/workers",             to: "queue#workers"
        post "queue/reap_stale_runs",     to: "queue#reap_stale_runs"

        # Overview + stuck list (mirror F).
        get "overview", to: "overview#show"
        get "stuck",    to: "overview#stuck"

        # Operator console kill switches.
        get  "console",                 to: "console#show"
        post "console/pause_polling",   to: "console#pause_polling"
        post "console/unpause_polling", to: "console#unpause_polling"
        post "console/pause_runs",      to: "console#pause_runs"
        post "console/unpause_runs",    to: "console#unpause_runs"

        # Per-instance version info — returns the SHA + role of the
        # pod handling THIS request (`request_handler`) plus every
        # other live instance (`instances`) with a fresh heartbeat.
        # Use to verify a deploy has finished rolling: during a
        # rolling deploy you'll see both old + new SHAs simultaneously.
        get "version", to: "versions#index"

        # User directory for external admin API clients.
        resources :users, only: %i[ index show ]

        # Workflow control — the same mutations the HTML admin UI
        # exposes, but available programmatically. The :show action
        # returns one Workflow's full state (steps + runs +
        # diagnostics) without dragging in every sibling workflow
        # the way `/api/v1/admin/jobs/:id` does.
        get  "workflows/:id",                   to: "workflows#show"
        post "workflows/:id/retry_step",        to: "workflows#retry_step"
        post "workflows/:id/cleanup_workspace", to: "workflows#cleanup_workspace"

        # Subprocess inventory for external admin API clients.
        # Index supports ?state=running|finished|all (default
        # "active_or_recent"), ?kind=, ?hostname=, ?since=,
        # ?run_id=, ?workflow_id=. Detail returns the same payload
        # plus host metrics (cpu_percent, rss_bytes) when running.
        # Kill flips kill_requested_at — the owning worker pod
        # polls that flag and terminates the local pid; the response
        # returns the updated row immediately.
        resources :processes, only: %i[ index show ], controller: "spawned_processes" do
          member do
            post :kill
          end
        end
      end
    end
  end
  get "repositories", to: "spa#show", as: :repositories
  get "repositories/new", to: "spa#show", as: :new_repository
  get "repositories/:id/edit", to: "spa#show", as: :edit_repository, constraints: { id: /\d+/ }
  get "repositories/:id", to: "spa#show", as: :repository, constraints: { id: /\d+/ }
  resources :repositories, only: [] do
    # Repository-scoped chat routes were retired — the chat surface is
    # the top-level /chats/new and /chats/:id SPA routes, backed by the
    # /api/v1/app/chats endpoints.
    # The repository chat home (no tab, no UI entry point) is gone;
    # the per-repo controller was pure duplication of the top-level chat flow.
    get "documents", to: "spa#show", as: :documents
    get "scheduled_tasks", to: "spa#show", as: :scheduled_tasks
  end
  get "repositories/:repository_id/scheduled_tasks/new", to: "spa#show", as: :new_repository_scheduled_task

  get "chats/new", to: "spa#show", as: :new_chat
  get "chats/:id", to: "spa#show", as: :chat, constraints: { id: /\d+/ }

  get "scheduled_tasks", to: "spa#show", as: :scheduled_tasks
  get "documents", to: "spa#show", as: :documents
  get "scheduled_tasks/:id", to: "spa#show", as: :scheduled_task, constraints: { id: /\d+/ }
  get "scheduled_tasks/:id/edit", to: "spa#show", as: :edit_scheduled_task, constraints: { id: /\d+/ }
  get "app-shell", to: "spa#show", as: :app_shell
  get "app-shell/*path", to: "spa#show", as: :app_shell_route
  get "dashboard", to: "spa#show", as: :dashboard
  get "dashboard/epics", to: "spa#show", as: :dashboard_epics
  get "dashboard/jobs", to: "spa#show", as: :dashboard_jobs
  get "dashboard/workflows", to: "spa#show", as: :dashboard_workflows
  get "jobs", to: redirect(status: 302) { |_params, request|
    query = request.query_parameters.except("subject").to_query
    query.present? ? "/dashboard/jobs?#{query}" : "/dashboard/jobs"
  }
  get "workflows", to: redirect(status: 302) { |_params, request|
    query = request.query_parameters.except("subject").to_query
    query.present? ? "/dashboard/workflows?#{query}" : "/dashboard/workflows"
  }

  get "epics", to: redirect(status: 302) { |_params, request|
    query = request.query_parameters.except("subject").to_query
    query.present? ? "/dashboard/epics?#{query}" : "/dashboard/epics"
  }, as: :epics
  get "epics/new", to: "spa#show", as: :new_epic
  get "epics/:id", to: "spa#show", as: :epic, constraints: { id: /\d+/ }
  get "epics/:id/edit", to: "spa#show", as: :edit_epic, constraints: { id: /\d+/ }
  get "smart_folders", to: "spa#show", as: :smart_folders
  get "tags", to: "spa#show", as: :tags
  get "cron_templates", to: "spa#show", as: :cron_templates
  get "cron_templates/new", to: "spa#show", as: :new_cron_template
  get "cron_templates/:id", to: "spa#show", as: :cron_template, constraints: { id: /\d+/ }
  get "cron_templates/:id/edit", to: "spa#show", as: :edit_cron_template, constraints: { id: /\d+/ }
  get "invitations", to: "spa#show", as: :invitations
  # Legacy compatibility: the account menu's `/settings` entry is the
  # per-user credentials page. App-wide settings live at `/settings/edit`
  # and remain admin-only.
  get "settings", to: "spa#show"
  get "settings/edit", to: "spa#show", as: :edit_settings
  get "jobs/new", to: "spa#show", as: :new_job
  get "jobs/:id/source", to: "spa#show", as: :source_job, constraints: { id: /\d+/ }
  get "jobs/:id", to: "spa#show", as: :job, constraints: { id: /\d+/ }
  get "admin", to: "spa#show", as: :admin_root
  get "admin/queue", to: "spa#show", as: :admin_queue_root
  get "admin/queue/:tab", to: "spa#show", as: :admin_queue, constraints: { tab: /active|pending|failed|recurring|workers/ }
  get "admin/stuck", to: "spa#show", as: :admin_stuck
  get "admin/processes", to: "spa#show", as: :admin_processes
  get "admin/processes/:id", to: "spa#show", as: :admin_process, constraints: { id: /\d+/ }
  get "admin/runs/:run_id/transcript", to: "spa#show", as: :admin_run_transcript, constraints: { run_id: /\d+/ }
  get "admin/users", to: "spa#show", as: :admin_users
  get "admin/users/:id", to: "spa#show", as: :admin_user, constraints: { id: /\d+/ }
  get "admin/console", to: "spa#show", as: :admin_console
  get "admin/installations", to: "spa#show", as: :admin_installations
  get "admin/github_app/register", to: "spa#show", as: :admin_github_app_register
  get "admin/github_app/confirm", to: "spa#show", as: :admin_github_app_confirm

  namespace :admin do
    # Raw transcript download for offline analysis.
    get "runs/:run_id/transcript/download", to: "transcripts#download", as: :run_transcript_download

    get "github_app/callback", to: "github_app#callback", as: :github_app_callback
  end

  root "spa#show"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
