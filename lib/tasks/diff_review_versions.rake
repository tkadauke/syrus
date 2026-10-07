namespace :syrus do
  desc "Backfill final All changes diff review snapshots for closed Jobs"
  task backfill_final_diff_review_versions: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "false"))
    result = Jobs::DiffReviewVersionBackfill.new.call(dry_run: dry_run)

    puts [
      "checked=#{result.checked}",
      "created=#{result.created}",
      "reused=#{result.reused}",
      "skipped=#{result.skipped}",
      "errors=#{result.errors}",
      "dry_run=#{dry_run}"
    ].join(" ")

    result.skips.each do |skip|
      puts "skipped job_id=#{skip.fetch("job_id")} reason=#{skip.fetch("reason")}"
    end
  end
end
