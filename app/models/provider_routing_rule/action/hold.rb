class ProviderRoutingRule::Action::Hold < ProviderRoutingRule::Action
  def hold? = true

  def serialize
    attributes.except("strategy", "candidates").merge("type" => "hold")
  end

  def validate(record)
    record.errors.add(:action, "hold reason must be a string") if attributes.key?("reason") && !attributes["reason"].is_a?(String)
  end
end
