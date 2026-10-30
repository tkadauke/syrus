class Coworkers::GrantPolicy
  RANKS = {
    "off" => 0,
    "queue" => 1,
    "confirm" => 2,
    "auto" => 3
  }.freeze

  def self.for(name)
    new(RANKS.fetch(name.to_s))
  end

  def initialize(rank) = @rank = rank
  def escalation_from?(current) = rank > self.class.for(current).rank

  attr_reader :rank
end
