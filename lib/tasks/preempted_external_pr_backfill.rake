namespace :syrus do
  desc "Reopen closed/preempted issue Jobs whose external PR is still open"
  task backfill_preempted_external_pr_jobs: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "false"))
    result = Jobs::PreemptedExternalPrBackfill.new.call(dry_run: dry_run)

    puts [
      "checked=#{result.checked}",
      "reopened=#{result.reopened}",
      "skipped=#{result.skipped}",
      "errors=#{result.errors}",
      "dry_run=#{dry_run}"
    ].join(" ")
  end
end
