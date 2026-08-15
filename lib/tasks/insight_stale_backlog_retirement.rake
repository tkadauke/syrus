namespace :syrus do
  desc "Retire legacy stale InsightSuggestion rows (revise_existing_insight, 'Superseded by #N' informational cards)"
  task retire_stale_insight_backlog: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "false"))
    result = InsightSuggestions::StaleBacklogRetirement.new.call(dry_run: dry_run)

    puts [
      "checked=#{result.checked}",
      "retired=#{result.retired}",
      "skipped=#{result.skipped}",
      "errors=#{result.errors}",
      "dry_run=#{dry_run}"
    ].join(" ")
  end
end
