module Syrus
  module Metrics
    # What the registry hands back in production for a metric nobody declared:
    # something that swallows every instrument call so the call site keeps
    # working.
    #
    # A missing series is a far better outcome than a failed Run, and the
    # mistake is still surfaced -- it raises in development and test, and logs
    # once in production.
    class NullInstrument
      attr_reader :name, :type

      def initialize(name, type)
        @name = name
        @type = type
      end

      def increment(*, **) = nil
      def decrement(*, **) = nil
      def set(*, **) = nil
      def observe(*, **) = nil
      def preset(*, **) = nil
      def samples = []
      def empty? = true
      def buckets = []
      def measure(**) = yield
    end
  end
end
