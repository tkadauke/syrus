class ProviderRoutingRule::Action::Route::Strategy::Unknown < ProviderRoutingRule::Action::Route::Strategy
  def validate(record)
    record.errors.add(:action, :unknown_strategy, value: attributes["strategy"].to_s.inspect)
  end
end
