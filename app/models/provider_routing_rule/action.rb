class ProviderRoutingRule::Action
  TYPES = {}.freeze

  def self.for(payload, legacy_candidates: [])
    attributes = payload.respond_to?(:to_h) ? payload.to_h.deep_stringify_keys : {}
    type = attributes["type"].presence || "route"
    { "route" => Route, "hold" => Hold }.fetch(type, Unknown).new(attributes, legacy_candidates: legacy_candidates)
  end

  attr_reader :attributes, :legacy_candidates

  def initialize(attributes, legacy_candidates: [])
    @attributes = attributes
    @legacy_candidates = legacy_candidates
  end

  def type = attributes["type"].presence || "route"
  def candidates = []
  def hold? = false

  def serialize
    attributes.merge("type" => type)
  end

  def validate(record)
    record.errors.add(:action, "has unknown type #{type.inspect}")
  end
end
