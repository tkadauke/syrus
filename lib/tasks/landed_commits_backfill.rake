namespace :syrus do
  desc "One-off backfill: populate landed_commits for historical landings on one repository"
  task :backfill_landed_commits, [ :repo_slug ] => :environment do |_, args|
    repo_slug = args[:repo_slug].presence || ENV["REPO"]
    if repo_slug.blank?
      abort 'Usage: bin/rails "syrus:backfill_landed_commits[owner/repo]" (or REPO=owner/repo bin/rails syrus:backfill_landed_commits)'
    end

    owner, name = repo_slug.split("/", 2)
    repository = Repository.find_by(owner: owner, name: name)
    abort "Repository #{repo_slug} not found" unless repository

    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "false"))
    result = Jobs::LandedCommitsBackfill.new(repository: repository).call(dry_run: dry_run)

    puts [
      "repo=#{repo_slug}",
      "checked=#{result.checked}",
      "recorded=#{result.recorded}",
      "commits_recorded=#{result.commits_recorded}",
      "skipped=#{result.skipped}",
      "errors=#{result.errors}",
      "dry_run=#{dry_run}"
    ].join(" ")
  end
end
