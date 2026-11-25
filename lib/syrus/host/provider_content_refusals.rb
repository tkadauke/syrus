module Syrus
  module Host
    # Lets an agent provider plugin report a safety-filter refusal of the
    # content it was given, so core retries the step on another provider
    # instead of resuming into the same refusal.
    module ProviderContentRefusals
      def self.outcome = ::ProviderContentRefusal::OUTCOME
      def self.detect?(text) = ::ProviderContentRefusal.detect?(text)
    end
  end
end
