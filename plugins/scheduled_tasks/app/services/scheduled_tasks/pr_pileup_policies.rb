module ScheduledTasks
  module PrPileupPolicies
    REGISTRY = {
      "skip"    => "ScheduledTasks::PrPileupPolicies::SkipPolicy",
      "replace" => "ScheduledTasks::PrPileupPolicies::ReplacePolicy",
      "pile"    => "ScheduledTasks::PrPileupPolicies::PilePolicy"
    }.freeze

    def self.for(name)
      class_name = REGISTRY[name.to_s] or raise ConfigurationError, "Unknown pr_pileup_policy: #{name}"
      class_name.constantize
    end

    ConfigurationError = Class.new(StandardError)
  end
end
