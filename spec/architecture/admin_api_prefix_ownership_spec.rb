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
    POST /api/v1/app/admin/jobs/:job_id/dependencies/override api/v1/app/admin/job_metadata#override_dependencies
    POST /api/v1/app/admin/jobs/:job_id/force_fail api/v1/app/admin/job_lifecycle#force_fail
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

  REVIEWED_PLUGIN_APP_ADMIN_ROUTES = <<~ROUTES.lines.map(&:strip).reject(&:blank?).freeze
    admin_mysql GET /api/v1/app/admin/mysql api/v1/app/admin/mysql#show
    admin_mysql POST /api/v1/app/admin/mysql/kill_query api/v1/app/admin/mysql#kill_query
    agent_activity GET /api/v1/app/admin/agent_activity/sessions api/v1/app/admin/agent_activity#sessions
    agent_activity GET /api/v1/app/admin/agent_activity/sessions/:run_id/artifacts api/v1/app/admin/agent_activity#artifacts
    agent_insights GET /api/v1/app/admin/insights api/v1/app/admin/insights#index
    agent_insights POST /api/v1/app/admin/insights/:id/promote_memory api/v1/app/admin/insights#promote_memory
    build_cache GET /api/v1/app/admin/build_cache api/v1/app/admin/build_cache#show
    build_cache GET /api/v1/app/admin/build_cache/stats api/v1/app/admin/build_cache#stats
    build_cache POST /api/v1/app/admin/build_cache/clear_requests api/v1/app/admin/build_cache#create_clear_request
    build_cache POST /api/v1/app/admin/build_cache/clear_requests/:id/cancel api/v1/app/admin/build_cache#cancel_clear_request
    build_cache POST /api/v1/app/admin/build_cache/clear_requests/:id/confirm api/v1/app/admin/build_cache#confirm_clear_request
    github_source GET /api/v1/app/admin/github_api_usage api/v1/app/admin/github_api_usage#show
    k8s_cluster DELETE /api/v1/app/admin/kubernetes_clusters/:id api/v1/app/admin/kubernetes_clusters#destroy
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters api/v1/app/admin/kubernetes_clusters#index
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/configmaps api/v1/app/admin/kubernetes_resources#configmaps
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/cronjobs api/v1/app/admin/kubernetes_resources#cronjobs
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/daemonsets api/v1/app/admin/kubernetes_resources#daemonsets
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/deployments api/v1/app/admin/kubernetes_resources#deployments
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/endpoints api/v1/app/admin/kubernetes_resources#endpoints
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/events api/v1/app/admin/kubernetes_resources#events
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/ingresses api/v1/app/admin/kubernetes_resources#ingresses
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/jobs api/v1/app/admin/kubernetes_resources#jobs
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/namespaces api/v1/app/admin/kubernetes_resources#namespaces
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/nodes api/v1/app/admin/kubernetes_resources#nodes
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/overview api/v1/app/admin/kubernetes_resources#overview
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/pods api/v1/app/admin/kubernetes_resources#pods
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/pods/:name/logs api/v1/app/admin/kubernetes_resources#pod_logs
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/pvcs api/v1/app/admin/kubernetes_resources#pvcs
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/secrets api/v1/app/admin/kubernetes_resources#secrets
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/services api/v1/app/admin/kubernetes_resources#services
    k8s_cluster GET /api/v1/app/admin/kubernetes_clusters/:id/statefulsets api/v1/app/admin/kubernetes_resources#statefulsets
    k8s_cluster PATCH /api/v1/app/admin/kubernetes_clusters/:id api/v1/app/admin/kubernetes_clusters#update
    k8s_cluster POST /api/v1/app/admin/kubernetes_clusters api/v1/app/admin/kubernetes_clusters#create
    k8s_cluster POST /api/v1/app/admin/kubernetes_clusters/:id/test api/v1/app/admin/kubernetes_clusters#test_connection
    k8s_cluster POST /api/v1/app/admin/kubernetes_clusters/test api/v1/app/admin/kubernetes_clusters#test_connection
    metrics_dashboard GET /api/v1/app/admin/metrics_dashboard api/v1/app/admin/metrics_dashboard#show
    mysql_db_browser DELETE /api/v1/app/admin/mysql_connections/:id api/v1/app/admin/mysql_connections#destroy
    mysql_db_browser GET /api/v1/app/admin/mysql_connections api/v1/app/admin/mysql_connections#index
    mysql_db_browser GET /api/v1/app/admin/mysql_connections/:id/schema api/v1/app/admin/mysql_schema#databases
    mysql_db_browser GET /api/v1/app/admin/mysql_connections/:id/schema/:database/query_builder api/v1/app/admin/mysql_query#query_builder
    mysql_db_browser GET /api/v1/app/admin/mysql_connections/:id/schema/:database/tables api/v1/app/admin/mysql_schema#tables
    mysql_db_browser GET /api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table api/v1/app/admin/mysql_schema#show
    mysql_db_browser GET /api/v1/app/admin/mysql_connections/:id/schema/:database/tables/:table/content api/v1/app/admin/mysql_query#content
    mysql_db_browser PATCH /api/v1/app/admin/mysql_connections/:id api/v1/app/admin/mysql_connections#update
    mysql_db_browser POST /api/v1/app/admin/mysql_connections api/v1/app/admin/mysql_connections#create
    mysql_db_browser POST /api/v1/app/admin/mysql_connections/:id/query api/v1/app/admin/mysql_query#execute
    mysql_db_browser POST /api/v1/app/admin/mysql_connections/:id/test api/v1/app/admin/mysql_connections#test_connection
    mysql_db_browser POST /api/v1/app/admin/mysql_connections/test api/v1/app/admin/mysql_connections#test_connection
    plugin_runtime DELETE /api/v1/app/admin/plugin_services/volumes/:name api/v1/app/admin/plugin_services#remove_volume
    plugin_runtime GET /api/v1/app/admin/plugin_services api/v1/app/admin/plugin_services#index
    plugin_runtime GET /api/v1/app/admin/plugin_services/:name/details api/v1/app/admin/plugin_services#details
    plugin_runtime GET /api/v1/app/admin/plugin_services/:name/logs api/v1/app/admin/plugin_services#logs
    plugin_runtime POST /api/v1/app/admin/plugin_services/:name/restart api/v1/app/admin/plugin_services#restart
    plugin_runtime POST /api/v1/app/admin/plugin_services/:name/start api/v1/app/admin/plugin_services#start
    plugin_runtime POST /api/v1/app/admin/plugin_services/:name/stop api/v1/app/admin/plugin_services#stop
    syrus_dev GET /api/v1/app/admin/operational_logs api/v1/app/admin/operational_logs#index
    syrus_dev GET /api/v1/app/admin/performance api/v1/app/admin/performance#show
    syrus_dev POST /api/v1/app/admin/performance/explain api/v1/app/admin/performance#explain
    syrus_dev POST /api/v1/app/admin/tool_card_jobs api/v1/app/admin/tool_card_jobs#create
    tailscale GET /api/v1/app/admin/tailscale/status api/v1/app/admin/tailscale#status
    worker_timeline GET /api/v1/app/admin/worker_timeline/live api/v1/app/admin/worker_timeline#live
    worker_timeline GET /api/v1/app/admin/worker_timeline/macro api/v1/app/admin/worker_timeline#macro
    worker_timeline GET /api/v1/app/admin/worker_timeline/workflow api/v1/app/admin/worker_timeline#workflow
  ROUTES

  REVIEWED_INLINE_ADMIN_CHECKS_IN_USER_APP_API = <<~ROUTES.lines.map(&:strip).reject(&:blank?).freeze
    GET /api/v1/app/jobs/:id/timeline api/v1/app/jobs#timeline
    GET /api/v1/app/maintenance_tasks/sidebar api/v1/app/maintenance_tasks#sidebar
  ROUTES

  REVIEWED_PLUGIN_OPERATOR_ADMIN_ROUTES = <<~ROUTES.lines.map(&:strip).reject(&:blank?).freeze
    admin_mysql GET /api/v1/admin/mysql api/v1/admin/mysql#show
    admin_mysql POST /api/v1/admin/mysql/kill_query api/v1/admin/mysql#kill_query
    build_cache GET /api/v1/admin/build_cache api/v1/admin/build_cache#show
    design_docs GET /api/v1/admin/design_docs api/v1/admin/design_docs#index
    design_docs GET /api/v1/admin/design_docs/:id api/v1/admin/design_docs#show
    design_docs GET /api/v1/admin/design_docs/:id/versions api/v1/admin/design_docs#versions
    design_docs PATCH /api/v1/admin/design_docs/:id api/v1/admin/design_docs#update
    design_docs POST /api/v1/admin/design_docs api/v1/admin/design_docs#create
    scheduled_tasks GET /api/v1/admin/cron_templates api/v1/admin/cron_templates#index
    scheduled_tasks GET /api/v1/admin/cron_templates/:id api/v1/admin/cron_templates#show
    scheduled_tasks GET /api/v1/admin/scheduled_tasks api/v1/admin/scheduled_tasks#index
    scheduled_tasks GET /api/v1/admin/scheduled_tasks/:id api/v1/admin/scheduled_tasks#show
    scheduled_tasks POST /api/v1/admin/scheduled_tasks/:id/fire api/v1/admin/scheduled_tasks#fire
    scheduled_tasks POST /api/v1/admin/scheduled_tasks/:id/pause api/v1/admin/scheduled_tasks#pause
    scheduled_tasks POST /api/v1/admin/scheduled_tasks/:id/unpause api/v1/admin/scheduled_tasks#unpause
    syrus_dev GET /api/v1/admin/operational_logs api/v1/admin/operational_logs#index
    syrus_dev GET /api/v1/admin/performance api/v1/admin/performance#show
    syrus_dev POST /api/v1/admin/performance/explain api/v1/admin/performance#explain
    tailscale GET /api/v1/admin/tailscale/status api/v1/admin/tailscale#status
    terminal GET /api/v1/admin/terminal_sessions api/v1/admin/terminal_sessions#index
    terminal GET /api/v1/admin/terminal_sessions/:id api/v1/admin/terminal_sessions#show
    terminal POST /api/v1/admin/terminal_sessions/:id/kill api/v1/admin/terminal_sessions#kill
    test_insights GET /api/v1/admin/jobs/:job_id/test_results api/v1/admin/job_test_results#index
    test_insights GET /api/v1/admin/repositories/:repository_id/tests api/v1/admin/repository_tests#index
    test_insights GET /api/v1/admin/repositories/:repository_id/tests/:id api/v1/admin/repository_tests#show
    throughput GET /api/v1/admin/throughput api/v1/admin/throughput#show
    worker_timeline GET /api/v1/admin/worker_timeline/live api/v1/admin/worker_timeline#live
    worker_timeline GET /api/v1/admin/worker_timeline/macro api/v1/admin/worker_timeline#macro
    worker_timeline GET /api/v1/admin/worker_timeline/workflow api/v1/admin/worker_timeline#workflow
  ROUTES

  def admin_api_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/api/v1/app/admin") || path.start_with?("/api/v1/admin")
      next if path.include?("*plugin_route")

      [route.verb.to_s, path, "#{route.defaults[:controller]}##{route.defaults[:action]}"].join(" ")
    end
  end

  def plugin_admin_api_routes
    Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      Array(metadata[:routes]).filter_map do |raw_route|
        route = raw_route.to_h.with_indifferent_access
        path = route[:path].to_s
        next unless path.start_with?("/api/v1/app/admin") || path.start_with?("/api/v1/admin")

        [
          manifest.name,
          (route[:verb].presence || "GET").to_s.upcase,
          path,
          route[:controller].to_s
        ].join(" ")
      end
    end.sort
  end

  def app_user_api_routes
    core = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/api/v1/app/")
      next if path.start_with?("/api/v1/app/admin/")
      next if path.include?("*plugin_route")

      [ route.verb.to_s, path, "#{route.defaults[:controller]}##{route.defaults[:action]}" ].join(" ")
    end

    plugin = Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
      metadata = manifest.metadata.with_indifferent_access
      Array(metadata[:routes]).filter_map do |raw_route|
        route = raw_route.to_h.with_indifferent_access
        path = route[:path].to_s
        next unless path.start_with?("/api/v1/app/")
        next if path.start_with?("/api/v1/app/admin/")

        [
          (route[:verb].presence || "GET").to_s.upcase,
          path,
          route[:controller].to_s
        ].join(" ")
      end
    end

    core + plugin
  end

  def inline_admin_check_routes
    app_user_api_routes.select do |route|
      _verb, _path, endpoint = route.split(" ", 3)
      controller_name, action = endpoint.split("#", 2)
      inline_admin_refusal?(action_source(controller_name, action))
    end.sort
  end

  def inline_admin_refusal?(source)
    source.match?(/unless\s+Current\.user(?:&\.)?admin\?.*?render_error/m) ||
      source.match?(/return\s+render\b.*unless\s+Current\.user(?:&\.)?admin\?/)
  end

  def action_source(controller_name, action)
    controller_class = "#{controller_name}_controller".camelize.constantize
    source_path, line_number = controller_class.instance_method(action).source_location
    lines = File.readlines(source_path)
    start = line_number - 1
    indent = lines.fetch(start)[/^\s*/]
    finish = ((start + 1)...lines.length).find do |index|
      lines[index].match?(/^#{Regexp.escape(indent)}(?:def|private|protected)\b/)
    end || lines.length

    lines[start...finish].join
  rescue NameError
    ""
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

  it "keeps plugin app-admin routes on the reviewed UI-serving list" do
    current = plugin_admin_api_routes.select { |route| route.include?(" /api/v1/app/admin/") }

    expect(current).to match_array(REVIEWED_PLUGIN_APP_ADMIN_ROUTES), <<~MSG
      Plugin-declared /api/v1/app/admin routes are dispatched through the Rails
      wildcard, but they still serve the admin React UI. If this route is
      UI-only, update the reviewed list and config/syrus_docs/admin_api_prefixes.md.
      If it is scriptable operator surface, declare it under /api/v1/admin instead.
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

  it "keeps plugin operator-admin routes on the reviewed token-only list" do
    current = plugin_admin_api_routes.select { |route| route.include?(" /api/v1/admin/") }

    expect(current).to match_array(REVIEWED_PLUGIN_OPERATOR_ADMIN_ROUTES), <<~MSG
      Plugin-declared /api/v1/admin routes are token-only operator automation
      surface. If this route is a page-shaped admin UI endpoint, declare it
      under /api/v1/app/admin instead. Otherwise update the reviewed list and
      config/syrus_docs/admin_api_prefixes.md.
    MSG
  end

  it "keeps inline admin checks out of the user app API" do
    expect(inline_admin_check_routes).to match_array(REVIEWED_INLINE_ADMIN_CHECKS_IN_USER_APP_API), <<~MSG
      /api/v1/app is the user-facing API. Admin-only actions should live under
      /api/v1/app/admin for the React app or /api/v1/admin for token-only
      operator automation. Keep only deliberately reviewed legacy exceptions
      here.
    MSG
  end

  it "documents the prefix rule and known migration gaps" do
    doc = Rails.root.join("config/syrus_docs/admin_api_prefixes.md").read

    expect(doc).to include("`/api/v1/admin/*` is the operator and automation API")
    expect(doc).to include("`/api/v1/app/admin/*` serves the admin UI")
    expect(doc).to include("Gaps implied by the rule")
  end
end
