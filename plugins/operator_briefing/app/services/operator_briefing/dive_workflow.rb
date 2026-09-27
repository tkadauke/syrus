module OperatorBriefing
  class DiveWorkflow < ::Workflows::Base
    steps :prepare, :briefing_dive_investigate, :submit_dive_report

    def self.trigger_kind = "briefing_dive"

    def self.queue_name = :runs

    def self.steps_for(job)
      prepare_then(job, "briefing_dive_investigate", "submit_dive_report")
    end
  end
end
