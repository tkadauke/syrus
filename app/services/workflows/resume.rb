module Workflows
  # Operator-triggered continuation of a captured provider session.
  class Resume < Base
    steps :manual

    def self.trigger_kind = "resume"
  end
end
