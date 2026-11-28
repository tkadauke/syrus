module RuntimeImages
  module Verifications
    # Exposes each candidate contract assertion as its own durable verifier
    # while executing the confined probe only once per verification attempt.
    class CandidateSuite
      def self.check_keys
        %w[base_ancestry oci_metadata runtime_abi confinement] +
          RuntimeAbi.providers.keys.map { |key| "provider_#{key}" } + [ "smoke_test" ]
      end

      def initialize(probe)
        @probe = probe
        @mutex = Mutex.new
        @results = {}
      end

      def result(image, context)
        key = [ image.id, context[:build_request_id] ]
        @mutex.synchronize { @results[key] ||= @probe.call(image: image, build_request_id: context[:build_request_id]) }
      end
    end
  end
end
