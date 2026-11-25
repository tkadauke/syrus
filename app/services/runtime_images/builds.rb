module RuntimeImages
  # The runtime image build plane. Builds are requested durably, deduplicated by
  # source+recipe identity, and executed by a pluggable builder that is
  # registered by whatever provides the isolated build environment. With no
  # builder registered nothing is ever claimed, so the plane stays dark.
  module Builds
    class Error < StandardError; end

    # The request can never be built as stated (mutable source, unsupported
    # platform, oversized recipe). Recorded as a terminal "rejected" request.
    class Rejected < Error
      attr_reader :code

      def initialize(code, message = code.to_s)
        @code = code.to_s
        super(message)
      end
    end

    # A build or verification failed. +retryable+ failures consume the next
    # attempt when the request has one left.
    class BuildFailed < Error
      attr_reader :code, :retryable

      def initialize(message, code: "build_failed", retryable: false)
        @code = code.to_s
        @retryable = retryable
        super(message)
      end
    end

    # Raised by a builder that noticed cancellation was requested.
    class Canceled < Error; end

    class << self
      # Test seam and registration point: any object responding to
      # build(request:, attempt:, control:) returning a Builds::Output.
      attr_writer :builder

      def builder = @builder
      def builder_available? = !builder.nil?
    end
  end
end
