module Mcp::ControlToolContracts
  def self.states(states)
    states.map { |state| "`#{state}`" }.join(", ")
  end
end
