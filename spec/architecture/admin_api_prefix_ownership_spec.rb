require "rails_helper"

# The route snapshot is intentionally explicit. The two admin prefixes serve
# different consumers; when a route changes, reviewers should see that choice
# instead of letting the split grow by accident. See
# config/syrus_docs/admin_api_prefixes.md.
RSpec.describe "admin API prefix ownership" do
  REVIEWED_APP_ADMIN_ROUTES = <<~ROUTES.lines.map(&:strip).reject(&:blank?).freeze
    GET /api/v1/app/admin/overview api/v1/app/admin/overview#show
    GET /api/v1/app/admin/worker_health api/v1/app/admin/worker_health#show
    GET /api/v1/app/admin/macos_worker_update api/v1/app/admin/macos_worker_updates#desired
    POST /api/v1/app/admin/macos_worker_update/report api/v1/app/admin/macos_worker_updates#report
    POST /api/v1/app/admin/macos_worker_update/advance api/v1/app/admin/macos_worker_updates#advance
    POST /api/v1/app/admin/macos_worker_update/drain api/v1/app/admin/macos_worker_updates#drain
    POST /api/v1/app/admin/macos_worker_update/clear api/v1/app/admin/macos_worker_updates#clear
    POST /api/v1/app/admin/macos_worker_update/force_terminate api/v1/app/admin/macos_worker_updates#force_terminate
    GET /api/v1/app/admin/plugins api/v1/app/admin/plugins#index
    POST /api/v1/app/admin/plugins/:name/enable api/v1/app/admin/plugins#enable
    POST /api/v1/app/admin/plugins/:name/disable api/v1/app/admin/plugins#disable
    GET /api/v1/app/admin/plugins/:name/config api/v1/app/admin/plugins#show_config
    PATCH /api/v1/app/admin/plugins/:name/config api/v1/app/admin/plugins#update_config
    GET /api/v1/app/admin/plugins/:name api/v1/app/admin/plugins#show
    GET /api/v1/app/admin/plugin_pages api/v1/app/admin/plugin_pages#index
    GET /api/v1/app/admin/plugin_services api/v1/app/admin/plugin_services#index
    GET /api/v1/app/admin/queue/:tab api/v1/app/admin/queue#show
    POST /api/v1/app/admin/queue/reap_stale_runs api/v1/app/admin/queue#reap_stale_runs
    GET /api/v1/app/admin/stuck api/v1/app/admin/stuck#index
    GET /api/v1/app/admin/activity api/v1/app/admin/workflow_activity#index
    GET /api/v1/app/admin/work_units api/v1/app/admin/work_units#index
    POST /api/v1/app/admin/maintenance_tasks/discover api/v1/app/admin/maintenance_tasks#discover
    POST /api/v1/app/admin/maintenance_tasks/:id/start api/v1/app/admin/maintenance_tasks#start
    POST /api/v1/app/admin/maintenance_tasks/:id/pause api/v1/app/admin/maintenance_tasks#pause
    POST /api/v1/app/admin/maintenance_tasks/:id/resume api/v1/app/admin/maintenance_tasks#resume
    POST /api/v1/app/admin/maintenance_tasks/:id/cancel api/v1/app/admin/maintenance_tasks#cancel
    POST /api/v1/app/admin/maintenance_tasks/:id/dismiss api/v1/app/admin/maintenance_tasks#dismiss
    GET /api/v1/app/admin/maintenance_tasks api/v1/app/admin/maintenance_tasks#index
    GET /api/v1/app/admin/maintenance_tasks/:id api/v1/app/admin/maintenance_tasks#show
    GET /api/v1/app/admin/reconciler_activity api/v1/app/admin/reconciler_activity#index
    GET /api/v1/app/admin/browser_errors api/v1/app/admin/browser_errors#index
    GET /api/v1/app/admin/backend_exceptions api/v1/app/admin/backend_exceptions#index
    GET /api/v1/app/admin/github_app/register api/v1/app/admin/github_app#register
    GET /api/v1/app/admin/github_app/confirm api/v1/app/admin/github_app#confirm
    POST /api/v1/app/admin/github_app/sync_installations api/v1/app/admin/github_app#sync_installations
    POST /api/v1/app/admin/processes/:id/kill api/v1/app/admin/spawned_processes#kill
    GET /api/v1/app/admin/processes api/v1/app/admin/spawned_processes#index
    GET /api/v1/app/admin/processes/:id api/v1/app/admin/spawned_processes#show
    GET /api/v1/app/admin/runs/:run_id/transcript api/v1/app/admin/transcripts#show
    GET /api/v1/app/admin/mcp_tool_usage api/v1/app/admin/mcp_tool_usage#show
    POST /api/v1/app/admin/users/:id/pause_scheduling api/v1/app/admin/users#pause_scheduling
    POST /api/v1/app/admin/users/:id/unpause_scheduling api/v1/app/admin/users#unpause_scheduling
    GET /api/v1/app/admin/users api/v1/app/admin/users#index
    GET /api/v1/app/admin/users/:id api/v1/app/admin/users#show
    PATCH /api/v1/app/admin/users/:id api/v1/app/admin/users#update
    PUT /api/v1/app/admin/users/:id api/v1/app/admin/users#update
    GET /api/v1/app/admin/console api/v1/app/admin/console#show
    POST /api/v1/app/admin/console/pause_polling api/v1/app/admin/console#pause_polling
    POST /api/v1/app/admin/console/unpause_polling api/v1/app/admin/console#unpause_polling
    POST /api/v1/app/admin/console/pause_runs api/v1/app/admin/console#pause_runs
    POST /api/v1/app/admin/console/unpause_runs api/v1/app/admin/console#unpause_runs
    POST /api/v1/app/admin/console/enable_merge_train api/v1/app/admin/console#enable_merge_train
    POST /api/v1/app/admin/console/disable_merge_train api/v1/app/admin/console#disable_merge_train
    POST /api/v1/app/admin/console/clear_github_cache api/v1/app/admin/console#clear_github_cache
    POST /api/v1/app/admin/restart api/v1/app/admin/restart#create
    GET /api/v1/app/admin/installations api/v1/app/admin/installations#index
    GET /api/v1/app/admin/installations/diagnostic api/v1/app/admin/installations#diagnostic
    POST /api/v1/app/admin/installations/refresh api/v1/app/admin/installations#refresh
    GET /api/v1/app/admin/invitations api/v1/app/admin/invitations#index
    POST /api/v1/app/admin/invitations api/v1/app/admin/invitations#create
    DELETE /api/v1/app/admin/invitations/:id api/v1/app/admin/invitations#destroy
    GET /api/v1/app/admin/features api/v1/app/admin/features#index
    PATCH /api/v1/app/admin/features/:slug api/v1/app/admin/features#update
    PUT /api/v1/app/admin/features/:slug api/v1/app/admin/features#update
    GET /api/v1/app/admin/settings api/v1/app/admin/settings#show
    PATCH /api/v1/app/admin/settings api/v1/app/admin/settings#update
    POST /api/v1/app/admin/settings/clear_secret api/v1/app/admin/settings#clear_secret
    GET /api/v1/app/admin/retention_settings api/v1/app/admin/retention_settings#show
    PATCH /api/v1/app/admin/retention_settings api/v1/app/admin/retention_settings#update
    GET /api/v1/app/admin/retention_archives/:id/download api/v1/app/admin/retention_archives#download
    GET /api/v1/app/admin/retention_archives api/v1/app/admin/retention_archives#index
    POST /api/v1/app/admin/platform_polling/start api/v1/app/admin/platform_polling#start
  ROUTES

  REVIEWED_OPERATOR_ADMIN_ROUTES = <<~ROUTES.lines.map(&:strip).reject(&:blank?).freeze
    POST /api/v1/admin/jobs/:id/force_fail api/v1/admin/jobs#force_fail
    GET /api/v1/admin/jobs api/v1/admin/jobs#index
    POST /api/v1/admin/jobs api/v1/admin/jobs#create
    GET /api/v1/admin/jobs/:id api/v1/admin/jobs#show
    GET /api/v1/admin/chats api/v1/admin/chats#index
    GET /api/v1/admin/chats/:id api/v1/admin/chats#show
    GET /api/v1/admin/epics api/v1/admin/epics#index
    POST /api/v1/admin/epics api/v1/admin/epics#create
    GET /api/v1/admin/epics/:id api/v1/admin/epics#show
    GET /api/v1/admin/runs api/v1/admin/runs#index
    GET /api/v1/admin/runs/:run_id/artifacts api/v1/admin/runs#artifacts
    GET /api/v1/admin/runs/:run_id/transcript api/v1/admin/transcripts#show
    GET /api/v1/admin/runs/:run_id/transcript/raw api/v1/admin/transcripts#raw
    GET /api/v1/admin/mcp_tool_usage api/v1/admin/mcp_tool_usage#show
    GET /api/v1/admin/queue/active api/v1/admin/queue#active
    GET /api/v1/admin/queue/pending api/v1/admin/queue#pending
    GET /api/v1/admin/queue/failed api/v1/admin/queue#failed
    GET /api/v1/admin/queue/recurring api/v1/admin/queue#recurring
    GET /api/v1/admin/queue/workers api/v1/admin/queue#workers
    POST /api/v1/admin/queue/reap_stale_runs api/v1/admin/queue#reap_stale_runs
    GET /api/v1/admin/overview api/v1/admin/overview#show
    GET /api/v1/admin/stuck api/v1/admin/overview#stuck
    GET /api/v1/admin/activity api/v1/admin/workflow_activity#index
    GET /api/v1/admin/reconciler_activity api/v1/admin/reconciler_activity#index
    GET /api/v1/admin/browser_errors api/v1/admin/browser_errors#index
    GET /api/v1/admin/backend_exceptions api/v1/admin/backend_exceptions#index
    GET /api/v1/admin/worker_health api/v1/admin/worker_health#show
    GET /api/v1/admin/plugins api/v1/admin/plugins#index
    POST /api/v1/admin/plugins/:name/enable api/v1/admin/plugins#enable
    POST /api/v1/admin/plugins/:name/disable api/v1/admin/plugins#disable
    GET /api/v1/admin/plugins/:name/config api/v1/admin/plugins#show_config
    PATCH /api/v1/admin/plugins/:name/config api/v1/admin/plugins#update_config
    GET /api/v1/admin/console api/v1/admin/console#show
    POST /api/v1/admin/console/pause_polling api/v1/admin/console#pause_polling
    POST /api/v1/admin/console/unpause_polling api/v1/admin/console#unpause_polling
    POST /api/v1/admin/console/pause_runs api/v1/admin/console#pause_runs
    POST /api/v1/admin/console/unpause_runs api/v1/admin/console#unpause_runs
    POST /api/v1/admin/console/enable_merge_train api/v1/admin/console#enable_merge_train
    POST /api/v1/admin/console/disable_merge_train api/v1/admin/console#disable_merge_train
    POST /api/v1/admin/restart api/v1/admin/restart#create
    GET /api/v1/admin/version api/v1/admin/versions#index
    GET /api/v1/admin/users api/v1/admin/users#index
    GET /api/v1/admin/users/:id api/v1/admin/users#show
    GET /api/v1/admin/workflows/:id api/v1/admin/workflows#show
    POST /api/v1/admin/workflows/:id/retry_step api/v1/admin/workflows#retry_step
    POST /api/v1/admin/workflows/:id/cleanup_workspace api/v1/admin/workflows#cleanup_workspace
    POST /api/v1/admin/processes/:id/kill api/v1/admin/spawned_processes#kill
    GET /api/v1/admin/processes api/v1/admin/spawned_processes#index
    GET /api/v1/admin/processes/:id api/v1/admin/spawned_processes#show
  ROUTES

  def admin_api_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/api/v1/app/admin") || path.start_with?("/api/v1/admin")
      next if path.include?("*plugin_route")

      [route.verb.to_s, path, "#{route.defaults[:controller]}##{route.defaults[:action]}"].join(" ")
    end
  end

  it "keeps app-admin routes on the reviewed UI-serving list" do
    current = admin_api_routes.select { |route| route.include?(" /api/v1/app/admin/") }

    expect(current).to match_array(REVIEWED_APP_ADMIN_ROUTES), <<~MSG
      /api/v1/app/admin is for the admin React UI, not new operator automation.
      If this route is UI-only, update the reviewed list and
      config/syrus_docs/admin_api_prefixes.md. If it is scriptable operator
      surface, put it under /api/v1/admin instead.
    MSG
  end

  it "keeps operator-admin routes on the reviewed token-only list" do
    current = admin_api_routes.select { |route| route.include?(" /api/v1/admin/") }

    expect(current).to match_array(REVIEWED_OPERATOR_ADMIN_ROUTES), <<~MSG
      /api/v1/admin is the token-only operator and automation API. If this
      route is a page-shaped admin UI endpoint, put it under /api/v1/app/admin
      instead. Otherwise update the reviewed list and
      config/syrus_docs/admin_api_prefixes.md.
    MSG
  end

  it "documents the prefix rule and known migration gaps" do
    doc = Rails.root.join("config/syrus_docs/admin_api_prefixes.md").read

    expect(doc).to include("`/api/v1/admin/*` is the operator and automation API")
    expect(doc).to include("`/api/v1/app/admin/*` serves the admin UI")
    expect(doc).to include("Gaps implied by the rule")
  end
end
