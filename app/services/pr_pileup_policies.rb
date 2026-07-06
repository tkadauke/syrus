module PrPileupPolicies
  REGISTRY = {
    "skip"    => "PrPileupPolicies::SkipPolicy",
    "replace" => "PrPileupPolicies::ReplacePolicy",
    "pile"    => "PrPileupPolicies::PilePolicy"
  }.freeze

  def self.for(name)
    class_name = REGISTRY[name.to_s] or raise ConfigurationError, "Unknown pr_pileup_policy: #{name}"
    class_name.constantize
  end

  ConfigurationError = Class.new(StandardError)
end
