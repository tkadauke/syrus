module ReviewPolicies
  class ConfigurationError < StandardError; end

  REGISTRY = {
    "self"       => "ReviewPolicies::SelfPolicy",
    "two_person" => "ReviewPolicies::TwoPersonPolicy",
    "final_say"  => "ReviewPolicies::FinalSayPolicy"
  }.freeze

  def self.for(policy_name)
    class_name = REGISTRY[policy_name.to_s]
    unless class_name
      raise ConfigurationError, "Unknown review policy: #{policy_name.inspect}"
    end

    class_name.constantize
  end
end
