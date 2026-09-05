require "scheduled_tasks/data_cleanup"

module ScheduledTasks
  extend Syrus::PluginApi

  syrus_plugin "scheduled_tasks" do
    display_name "Scheduled Tasks"
    description "Recurring and one-shot agent prompts attached to a repository, with no GitHub issue required."
    long_description "Scheduled Tasks fires agent work on a schedule: a cron expression or a one-shot datetime, a prompt, and a repository.\n\nEach fire creates a Job the normal pipeline picks up, so a schedule can survey a repository, refresh docs, or sweep for dead code without anyone filing an issue. \"No changes\" is an explicit happy path -- a survey that finds nothing closes successfully.\n\nIncludes reusable prompt/schedule templates, per-schedule auto-approval, and a pile-up policy for when the previous fire's PR is still open."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/scheduled_tasks.svg"
    author "Thomas Kadauke"
    category "input_source"
    default_enabled true
    disableable true
    # Due schedules are polled once a minute, the cadence the host's
    # recurring.yml used before this moved.
    tick_interval 1.minute

    provides callbacks: "ScheduledTasks::Callbacks",
             job_origin: "ScheduledTasks::JobOrigin",
             domain_subscriber: "ScheduledTasks::Subscribers",
             chat_mcp_tool_set: "ScheduledTasks::ChatToolSet",
             sidebar_page: "ScheduledTasks::SidebarPages",
             repo_page_tab: "ScheduledTasks::RepoPageTabs",
             repository_recommendation: "ScheduledTasks::Recommendations"

    route :get,    "/api/v1/app/cron_templates", to: "api/v1/app/cron_templates#index"
    route :post,   "/api/v1/app/cron_templates", to: "api/v1/app/cron_templates#create"
    route :post,   "/api/v1/app/cron_templates/preview_schedule", to: "api/v1/app/cron_templates#preview_schedule"
    route :get,    "/api/v1/app/cron_templates/:id", to: "api/v1/app/cron_templates#show"
    route :patch,  "/api/v1/app/cron_templates/:id", to: "api/v1/app/cron_templates#update"
    route :delete, "/api/v1/app/cron_templates/:id", to: "api/v1/app/cron_templates#destroy"

    route :get,    "/api/v1/app/repositories/:repository_id/scheduled_tasks/new", to: "api/v1/app/scheduled_tasks#new"
    route :get,    "/api/v1/app/repositories/:repository_id/scheduled_tasks", to: "api/v1/app/scheduled_tasks#repository_index"
    route :post,   "/api/v1/app/repositories/:repository_id/scheduled_tasks", to: "api/v1/app/scheduled_tasks#create"
    route :patch,  "/api/v1/app/repositories/:repository_id/scheduled_tasks/:id", to: "api/v1/app/scheduled_tasks#repository_update"
    route :delete, "/api/v1/app/repositories/:repository_id/scheduled_tasks/:id", to: "api/v1/app/scheduled_tasks#repository_destroy"
    route :get,    "/api/v1/app/scheduled_tasks/new", to: "api/v1/app/scheduled_tasks#new_repository_options"
    route :get,    "/api/v1/app/scheduled_tasks", to: "api/v1/app/scheduled_tasks#index"
    route :post,   "/api/v1/app/scheduled_tasks/preview_schedule", to: "api/v1/app/scheduled_tasks#preview_schedule"
    route :get,    "/api/v1/app/scheduled_tasks/:id", to: "api/v1/app/scheduled_tasks#show"
    route :patch,  "/api/v1/app/scheduled_tasks/:id", to: "api/v1/app/scheduled_tasks#update"
    route :delete, "/api/v1/app/scheduled_tasks/:id", to: "api/v1/app/scheduled_tasks#destroy"
    route :post,   "/api/v1/app/scheduled_tasks/:id/pause", to: "api/v1/app/scheduled_tasks#pause"
    route :post,   "/api/v1/app/scheduled_tasks/:id/resume", to: "api/v1/app/scheduled_tasks#resume"
    route :post,   "/api/v1/app/scheduled_tasks/:id/fire_now", to: "api/v1/app/scheduled_tasks#fire_now"


    frontend routes: { "scheduled_tasks/ScheduledTasksPage" => "app/frontend/routes/ScheduledTasksPage.tsx" }

    # Schedules only fire while the plugin is on; the rows outlive it being
    # disabled, so cleanup is installed with `always`.
    always do |scope|
      ScheduledTasks::DataCleanup.install_into(scope)
    end
  end
end
