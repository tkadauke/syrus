module AuthorizationContinuations
  class Origin
    def self.for(origin)
      resolver = descendants.find { |candidate| candidate.accepts?(origin) }
      resolver&.new(origin)
    end

    def self.accepts?(_origin) = false

    def initialize(origin)
      @origin = origin
    end

    def resumable? = raise NotImplementedError
    def deliver!(_payload) = raise NotImplementedError
    def dispatch! = raise NotImplementedError
    def complete_on_delivery? = true

    private

    attr_reader :origin
  end
end

require_dependency "authorization_continuations/chat_origin"
require_dependency "authorization_continuations/run_origin"
