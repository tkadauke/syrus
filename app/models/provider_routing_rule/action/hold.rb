class ProviderRoutingRule::Action::Hold < ProviderRoutingRule::Action
  RESUMPTION_MODES = ProviderRoutingHold::RESUMPTION_MODES

  def hold? = true

  def serialize
    attributes.except("strategy", "candidates").merge("type" => "hold")
  end

  def validate(record)
    record.errors.add(:action, "hold reason must be a string") if attributes.key?("reason") && !attributes["reason"].is_a?(String)
    policy = attributes["resumption"] || {}
    unless policy.is_a?(Hash)
      record.errors.add(:action, "hold resumption must be an object")
      return
    end

    mode = (policy["mode"] || "manual").to_s
    record.errors.add(:action, "hold resumption mode is unknown") unless RESUMPTION_MODES.include?(mode)
    if mode == "until_time"
      Time.zone.parse(policy["at"].to_s)
    end
  rescue ArgumentError, TypeError
    record.errors.add(:action, "hold resumption at must be an ISO 8601 time")
  end
end
