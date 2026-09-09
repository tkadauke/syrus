namespace :syrus do
  namespace :work_engine do
    desc "Run a deterministic work-engine simulation scenario YAML without persisting changes"
    task :simulate, [ :path ] => :environment do |_task, args|
      path = args[:path].presence || abort("usage: bin/rails syrus:work_engine:simulate[path/to/scenario.yml]")
      result = nil

      ActiveRecord::Base.transaction do
        result = WorkEngine::Simulation::ScenarioRunner.call(path: path)
        raise ActiveRecord::Rollback
      end

      puts "#{result.scenario}: #{result.status} after #{result.ticks} ticks"
      result.events.last(20).each { |event| puts "  #{event}" }
      if result.waiting?
        puts "waiting:"
        result.wait_reasons.each { |reason| puts "  #{reason}" }
      elsif !result.success?
        puts "stuck:"
        result.stuck_reasons.each { |reason| puts "  #{reason}" }
        exit 1
      end
    end
  end
end
