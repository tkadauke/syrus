namespace :syrus do
  desc "Print every coworker tool grouped by default policy (allow/ask/deny) with its reason; fails on contradictions"
  task coworker_tool_defaults: :environment do
    ActiveJob::Base # load Active Job before Coworkers::Create references ActiveJob::EnqueueError
    report = Coworkers::ToolDefaultPolicyReport.new
    puts report.to_text
    if report.findings.any?
      warn "\nInvariant violations:\n- #{report.findings.join("\n- ")}"
      exit 1
    end
  end
end
