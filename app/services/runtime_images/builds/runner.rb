module RuntimeImages
  module Builds
    # Executes one claimed attempt: build, then publish and verify through the
    # Runtime Image Service. All outcomes are recorded through the Orchestrator;
    # the builder never touches request state.
    class Runner
      # Handed to the builder so a long build can poll for cancellation and
      # renew its lease without knowing about requests.
      class Control
        def initialize(orchestrator, request, attempt)
          @orchestrator = orchestrator
          @request = request
          @attempt = attempt
        end

        def cancel_requested? = @orchestrator.cancel_requested?(@request)
        def heartbeat = @orchestrator.heartbeat(@attempt)

        def raise_if_canceled!
          raise Canceled if cancel_requested?
        end
      end

      def initialize(orchestrator: Orchestrator.new, service: Service.new, builder: nil)
        @orchestrator = orchestrator
        @service = service
        @builder = builder
      end

      def call(request, attempt)
        control = Control.new(@orchestrator, request, attempt)
        control.raise_if_canceled!
        output = builder.build(request: request, attempt: attempt, control: control)
        control.raise_if_canceled!
        verify_source!(request, output)
        @orchestrator.begin_verifying(attempt) || raise(Canceled)
        image = publish_and_verify(request, output)
        control.raise_if_canceled!
        @orchestrator.succeed(attempt, image: image)
      rescue Canceled
        @orchestrator.acknowledge_cancel(attempt)
      rescue BuildFailed => e
        @orchestrator.fail_attempt(attempt, code: e.code, message: e.message, retryable: e.retryable)
      rescue RuntimeImages::ProviderError, ActiveRecord::ConnectionNotEstablished, Timeout::Error, SystemCallError => e
        # Registry and infrastructure trouble is transient by nature.
        @orchestrator.fail_attempt(attempt, code: "infrastructure_error", message: "#{e.class}: #{e.message}", retryable: true)
      rescue StandardError => e
        @orchestrator.fail_attempt(attempt, code: "unexpected_error", message: "#{e.class}: #{e.message}", retryable: false)
      end

      private

      def builder
        @builder || Builds.builder || raise(BuildFailed.new("no build executor is registered", code: "builder_unavailable", retryable: true))
      end

      # The builder must have consumed exactly the source that was captured.
      def verify_source!(request, output)
        return if output.source_digest.blank? || output.source_digest == request.source_digest

        raise BuildFailed.new("built source #{output.source_digest} does not match captured #{request.source_digest}", code: "source_mismatch")
      end

      def publish_and_verify(request, output)
        image = @service.publish(
          namespace: request.runtime_image_namespace, source_kind: request.source_kind, source_ref: request.source_ref,
          source_digest: request.source_digest, platform: request.platform,
          provenance: Hash(output.provenance).merge("build_request_id" => request.id), payload: output.payload
        )
        inspection = @service.inspect_image(image)
        raise BuildFailed.new("published image #{image.digest} could not be verified", code: "verification_failed", retryable: true) unless inspection.present

        image
      end
    end
  end
end
