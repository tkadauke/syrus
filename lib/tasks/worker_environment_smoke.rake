namespace :syrus do
  desc "Run the worker environment smoke checks on this host, including plugin-contributed checks (JSON=1 for JSON)"
  task worker_environment_smoke: :environment do
    report = WorkerEnvironmentSmoke.new.call
    if ENV["JSON"].present?
      puts JSON.pretty_generate(report)
    else
      puts WorkerEnvironmentSmoke::Formatter.lines(report)
    end
    exit(1) if report["failed"].any?
  end
end
