module RuntimeImages
  module Verifications
    class CandidateVerifier
      def initialize(suite, key)
        @suite = suite
        @key = key
      end

      def call(image:, context:, **)
        @suite.result(image, context).fetch(@key)
      end
    end
  end
end
