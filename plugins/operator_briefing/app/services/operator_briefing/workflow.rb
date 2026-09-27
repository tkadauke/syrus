module OperatorBriefing
  class Workflow < ::Workflows::Base
    steps :prepare, :briefing_generate_run

    def self.trigger_kind = "briefing_generate"

    def self.queue_name = :runs

    def self.steps_for(job)
      prepare_then(job, "briefing_generate_run")
    end
  end
end
