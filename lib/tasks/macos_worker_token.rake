namespace :syrus do
  desc "Print a scoped bearer token for native macOS worker update polling"
  task macos_worker_token: :environment do
    days = Integer(ENV.fetch("DAYS", "30"), exception: false)
    abort "DAYS must be a positive integer" unless days&.positive?

    puts McpInvocationContext.issue_for_app_macos_worker(expires_in: days.days)
  end
end
