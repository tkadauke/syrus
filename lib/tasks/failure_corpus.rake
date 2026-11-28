namespace :failure_corpus do
  desc "Replay failure decisions against the production failure corpus and report changed verdicts (DIR=spec/fixtures/failure_corpus)"
  task replay: :environment do
    abort "failure_corpus:replay writes scratch rows; run it with RAILS_ENV=test or development" if Rails.env.production?

    require Rails.root.join("lib/failure_corpus/replay").to_s

    dir = ENV.fetch("DIR", FailureCorpus::Replay::DEFAULT_DIR)
    report = nil
    ActiveRecord::Base.transaction do
      report = FailureCorpus::Replay.call(dir: dir)
      raise ActiveRecord::Rollback
    end

    puts report
    exit 1 unless report.ok?
  end
end
