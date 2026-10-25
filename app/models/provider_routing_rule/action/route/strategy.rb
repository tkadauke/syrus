class ProviderRoutingRule::Action::Route::Strategy
  def self.for(name, attributes)
    {
      "fallback_order" => FallbackOrder,
      "weighted" => Weighted,
      "panel" => Panel
    }.fetch(name.to_s, Unknown).new(attributes)
  end

  def initialize(attributes)
    @attributes = attributes
  end

  def panel? = false
  def validate(_record) = nil

  private

  attr_reader :attributes
end
