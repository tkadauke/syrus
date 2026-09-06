namespace :syrus do
  desc "One-off repair: reconcile MergeTrainMember rows wrongly failed by a missing local git object"
  task :repair_merge_train_member_reconciliation, [ :repo_slug ] => :environment do |_, args|
    repo_slug = args[:repo_slug].presence || ENV["REPO"]

    repository = nil
    if repo_slug.present?
      owner, name = repo_slug.split("/", 2)
      repository = Repository.find_by(owner: owner, name: name)
      abort "Repository #{repo_slug} not found" unless repository
    end

    train_ids = ENV["TRAIN_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).map(&:to_i).presence
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "false"))

    result = Jobs::MergeTrainMemberReconciliationRepair.new(repository: repository).call(train_ids: train_ids, dry_run: dry_run)

    puts [
      "repo=#{repo_slug || "all"}",
      "train_ids=#{train_ids || "all"}",
      "checked=#{result.checked}",
      "repaired=#{result.repaired}",
      "skipped=#{result.skipped}",
      "errors=#{result.errors}",
      "dry_run=#{dry_run}"
    ].join(" ")
  end
end
