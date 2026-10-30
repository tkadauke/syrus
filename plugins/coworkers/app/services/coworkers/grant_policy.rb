class Coworkers::GrantPolicy
  ORDER = %w[off queue confirm auto].freeze

  def self.for(name)
    {
      "off" => Off,
      "queue" => Queue,
      "confirm" => Confirm,
      "auto" => Auto
    }.fetch(name.to_s).new
  end

  def escalation_from?(current) = rank > self.class.for(current).rank
  def rank = self.class::RANK

  class Off < Coworkers::GrantPolicy
    RANK = 0
  end

  class Queue < Coworkers::GrantPolicy
    RANK = 1
  end

  class Confirm < Coworkers::GrantPolicy
    RANK = 2
  end

  class Auto < Coworkers::GrantPolicy
    RANK = 3
  end
end
