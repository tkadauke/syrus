module Achievements
  module Evaluators
    # Earned by the first completed matching event for the owner. Later events
    # reach the same unique unlock and change nothing.
    class FirstOccurrence < Base
      private

      def earned?(_definition, _adapter) = true
    end
  end
end
