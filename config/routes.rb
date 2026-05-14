Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resources :users, only: %i[ new create ]

  resource :credentials, only: %i[ edit update ] do
    post :rotate_api_token
    delete :revoke_api_token
  end

  # Admin REST API. Token-based auth (per-user), JSON only.
  # See docs/plans/complete/admin-diagnostics.md for the endpoint plan.
  namespace :api do
    namespace :v1 do
      namespace :admin do
        # `#show` returns the deep-nested Job state (workflows + steps
        # + runs + diagnostics + claude_session metadata). `#index`
        # is a compact list — supports `?pr_number=`, `?issue_number=`,
        # `?repo=owner/name`, `?state=` to find a Job from external
        # references (a GH PR url, an issue link, etc.) so the agent
        # doesn't have to know the Syrus internal Job ID up front.
        resources :jobs, only: %i[ show index ]

        # Compact list of Runs for cross-Job investigations
        # ("show me everything that failed in the last hour"
        # without walking each Job's response). Filters via
        # ?state, ?since, ?trigger_kind, ?job_id; default ordering
        # is most-recently-finished first. Pagination via ?page +
        # ?per (max 100).
        get "runs", to: "runs#index"

        # Transcripts (mirror Admin::TranscriptsController; A in
        # docs/plans/complete/admin-diagnostics.md). Paginated event stream
        # via ?page= + ?per=, plus a raw-JSONL pass-through.
        get "runs/:run_id/transcript",     to: "transcripts#show"
        get "runs/:run_id/transcript/raw", to: "transcripts#raw"

        # Queue introspection (mirror Admin::QueueController; B).
        get  "queue/active",              to: "queue#active"
        get  "queue/pending",             to: "queue#pending"
        get  "queue/failed",              to: "queue#failed"
        get  "queue/recurring",           to: "queue#recurring"
        get  "queue/workers",             to: "queue#workers"
        post "queue/reap_stale_runs",     to: "queue#reap_stale_runs"

        # Overview + stuck list (mirror F).
        get "overview", to: "overview#show"
        get "stuck",    to: "overview#stuck"

        # User directory (mirror Admin::UsersController).
        resources :users, only: %i[ index show ]

        # Workflow control — the same mutations the HTML admin UI
        # exposes, but available programmatically. The :show action
        # returns one Workflow's full state (steps + runs +
        # diagnostics) without dragging in every sibling workflow
        # the way `/api/v1/admin/jobs/:id` does.
        get  "workflows/:id",                   to: "workflows#show"
        post "workflows/:id/retry_step",        to: "workflows#retry_step"
        post "workflows/:id/cleanup_workspace", to: "workflows#cleanup_workspace"
      end
    end
  end
  resources :repositories, except: [ :destroy ] do
    collection do
      get :owners
      get :repos
      get :branches
    end
    member do
      post :poll
      post :archive
      post :unarchive
      post :retry_failed_jobs
      get  :issues
      post :comment_issue
      post :close_issue
      post :delegate_issue
      post :bulk_issues
    end
    get  "chats",             to: "repositories/chats#show",    as: :chats
    post "chats",             to: "repositories/chats#create"
    post "chats/triage",      to: "repositories/chats#triage",  as: :chat_triage
    post "chats/:id/message", to: "repositories/chats#message", as: :chat_message
    post "chats/:id/stop",    to: "repositories/chats#stop",    as: :chat_stop
    post "chats/:id/refresh", to: "repositories/chats#refresh", as: :chat_refresh
    post "chats/:id/reset",   to: "repositories/chats#reset",   as: :chat_reset
    post "chat_pending_actions/:id/confirm", to: "repositories/chats#confirm_pending_action", as: :chat_pending_action_confirm
    delete "chat_pending_actions/:id", to: "repositories/chats#destroy_pending_action", as: :chat_pending_action
    get  "chats/:chat_id/whiteboard",   to: "repositories/whiteboards#show",   as: :chat_whiteboard
    patch "chats/:chat_id/whiteboard",  to: "repositories/whiteboards#update"
    resource :whiteboard, only: %i[ show update ], controller: "repositories/whiteboards"
    resources :notes, only: %i[ create destroy ], controller: "repositories/notes"
    resources :documents, only: %i[ index create destroy ], controller: "repositories/documents", shallow: true
    resources :proposals, only: %i[ index update destroy ], controller: "repositories/proposals" do
      member do
        get :file
        post :file
      end
      collection do
        get :file_bulk
        post :file_bulk
      end
    end
    resources :scheduled_tasks, only: %i[ index update destroy ], controller: "repositories/scheduled_tasks"
    resources :scheduled_tasks, only: %i[ new create ]
  end

  resources :scheduled_tasks, only: %i[ index show edit update destroy ] do
    member do
      post :pause
      post :resume
      post :fire_now    # manually fire an active task without waiting for cron
    end
  end
  resources :smart_folders, only: %i[ index create update destroy ]
  resources :cron_templates
  resources :invitations, only: %i[ index create destroy ]
  resource :settings, only: %i[ show edit update ]
  resources :bug_reports, only: %i[ create ]
  resources :jobs, only: %i[ show new create ] do
    resource :pin, only: %i[ create destroy ], controller: "job_pins"
    resources :attachments, only: %i[ create destroy ], controller: "job_attachments"

    member do
      post :start
      post :run_again      # soft retry — new Run on the existing branch
      post :restart        # hard reset — close this thread, open a new one with a fresh branch + PR
      post :cancel         # cancel active runs + close the thread
      post :reopen         # undo a close — closed → open, polling resumes
      post :poll_feedback  # manually trigger PollPullRequestJob for this Job
      post :rebase         # manually trigger a rebase Run on this Job's PR
      post :check_mergeability  # ask GitHub for the latest mergeable status now
      post :resume         # continue a failed Run via claude --resume
      post :stop_run       # cancel a single active Run without closing the thread
      post :retry_step     # re-run the failed step in a failed Workflow (keeps the existing workspace)
      post :push_commits   # push uncommitted/committed local changes from a failed Workflow's workspace
      post :operator_response # answer an ask_operator question and resume the Run
      get  :source         # browse the repo source at any branch commit or merge base
      post :diagnose       # capture a RunHealthSnapshot for an active Run
      get  "runs/:run_id/grade_log", action: :grade_log, as: :run_grade_log
      post :dependencies, action: :add_dependency
      delete "dependencies/:dependency_id", action: :remove_dependency, as: :dependency
      post :override_dependencies
    end
  end

  namespace :admin do
    # System overview — landing page for the admin area.
    # See docs/plans/complete/admin-diagnostics.md (F).
    root to: "overview#show"

    # Per-Run claude transcript viewer — renders the captured
    # ClaudeSession.transcript_jsonl as a structured event stream.
    # See docs/plans/complete/admin-diagnostics.md (A).
    get  "runs/:run_id/transcript",          to: "transcripts#show",     as: :run_transcript
    get  "runs/:run_id/transcript/download", to: "transcripts#download", as: :run_transcript_download

    # SolidQueue inspector — see docs/plans/complete/admin-diagnostics.md (B).
    get  "queue",                  to: "queue#index", as: :queue_root
    get  "queue/:tab",             to: "queue#show",            as: :queue, constraints: { tab: /active|pending|failed|recurring|workers/ }
    post "queue/reap_stale_runs",  to: "queue#reap_stale_runs", as: :reap_stale_runs

    # Stuck-things watchlist — Run heartbeat stale or Workflow
    # nearing prune. See Admin::StuckItems for the definition.
    get "stuck", to: "stuck#index", as: :stuck

    get  "installations",         to: "installations#index",   as: :installations
    post "installations/refresh", to: "installations#refresh", as: :installations_refresh

    # User directory — filterable list + per-user detail page.
    # Drilled into from the GH rate-limits tile on /admin (with
    # `?gh_rate=low`); also supports `?admin=true|false`,
    # `?email=substr`, `?has_github_token=true|false`,
    # `?has_claude_token=true|false`. Filter logic lives in
    # Admin::UsersFilter so the API mirror reuses it.
    resources :users, only: %i[ index show ] do
      member do
        post :pause_scheduling
        post :unpause_scheduling
      end
    end

    # Operator console — kill switches + audit log (L).
    get  "console",                    to: "console#show",              as: :console
    post "console/pause_polling",      to: "console#pause_polling",     as: :pause_polling
    post "console/unpause_polling",    to: "console#unpause_polling",   as: :unpause_polling
    post "console/pause_runs",         to: "console#pause_runs",        as: :pause_runs
    post "console/unpause_runs",       to: "console#unpause_runs",      as: :unpause_runs
    post "console/clear_github_cache", to: "console#clear_github_cache", as: :clear_github_cache

    get "github_app/register", to: "github_app#register", as: :github_app_register
    get "github_app/callback", to: "github_app#callback", as: :github_app_callback
    get "github_app/confirm",  to: "github_app#confirm",  as: :github_app_confirm
  end

  post "github_app/webhook", to: "github_app_webhooks#create", as: :github_app_webhook
  post "telegram/webhook", to: "telegram_webhooks#create", as: :telegram_webhook

  post "dashboard/jobs/bulk", to: "home#bulk_jobs", as: :bulk_dashboard_jobs
  root "home#index"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
