module RuntimeImages
  module Builds
    # Executes one claimed attempt: build, then publish and verify through the
    # Runtime Image Service. All outcomes are recorded through the Orchestrator;
    # the builder never touches request state.
    class Runner
      # Handed to the builder so a long build can poll for cancellation and
      # renew its lease without knowing about requests.
      class Control
        # Where the builder reports what it observed (log, network, resources).
        attr_reader :evidence

        def initialize(orchestrator, request, attempt, evidence = Evidence.new)
          @orchestrator = orchestrator
          @request = request
          @attempt = attempt
          @evidence = evidence
        end

        def cancel_requested? = @orchestrator.cancel_requested?(@request)
        def heartbeat = @orchestrator.heartbeat(@attempt)

        def raise_if_canceled!
          raise Canceled if cancel_requested?
        end
      end

      def initialize(orchestrator: Orchestrator.new, service: Service.new, builder: nil, recorder: EvidenceRecorder.new)
        @orchestrator = orchestrator
        @service = service
        @builder = builder
        @recorder = recorder
      end

      def call(request, attempt)
        evidence = Evidence.new
        control = Control.new(@orchestrator, request, attempt, evidence)
        control.raise_if_canceled!
        output = builder.build(request: request, attempt: attempt, control: control)
        control.raise_if_canceled!
        verify_source!(request, output)
        @orchestrator.begin_verifying(attempt) || raise(Canceled)
        image = publish_and_verify(request, output, evidence)
        control.raise_if_canceled!
        @orchestrator.succeed(attempt, image: image)
      rescue Canceled
        @orchestrator.acknowledge_cancel(attempt)
      rescue BuildFailed => e
        @orchestrator.fail_attempt(attempt, code: e.code, detail: e.message, retryable: e.retryable)
      rescue RuntimeImages::ProviderError, ActiveRecord::ConnectionNotEstablished, Timeout::Error, SystemCallError => e
        # Registry and infrastructure trouble is transient by nature.
        @orchestrator.fail_attempt(attempt, code: "infrastructure_error", detail: "#{e.class}: #{e.message}", retryable: true)
      rescue StandardError => e
        @orchestrator.fail_attempt(attempt, code: "unexpected_error", detail: "#{e.class}: #{e.message}", retryable: false)
      ensure
        # Every terminal path leaves evidence bound to the attempt's outcome.
        @recorder.record(request: request, attempt: attempt, evidence: evidence) if evidence
      end

      private

      def builder
        @builder || Builds.builder || raise(BuildFailed.new("no build executor is registered", code: "builder_unavailable", retryable: true))
      end

      # The builder must have consumed exactly the source that was captured.
      def verify_source!(request, output)
        raise BuildFailed.new("builder did not report the source digest it consumed", code: "source_unattested") if output.source_digest.blank?
        return if output.source_digest == request.source_digest

        raise BuildFailed.new("built source #{output.source_digest} does not match captured #{request.source_digest}", code: "source_mismatch")
      end

      # Publishing goes through a publisher scoped to this request's namespace;
      # the builder never sees the Service or any registry credential.
      def publish_and_verify(request, output, evidence)
        evidence.record_image(output.payload)
        publisher = ScopedPublisher.new(service: @service, request: request)
        image = publisher.publish(
          source_kind: request.source_kind, source_ref: request.source_ref,
          source_digest: request.source_digest, platform: request.platform,
          provenance: provenance_for(request, output, evidence), payload: output.payload
        )
        evidence.image_digest = image.digest
        inspection = publisher.inspect_image(image)
        raise BuildFailed.new("published image #{image.digest} could not be verified", code: "verification_failed", retryable: true) unless inspection.present

        image
      end

      # Builder-reported provenance plus the bindings that make the image
      # traceable to its inputs. Safe to store on the image: digests and names
      # only, never log text or resolved addresses.
      def provenance_for(request, output, evidence)
        Hash(output.provenance).merge(
          "build_request_id" => request.id, "recipe_digest" => request.recipe_digest,
          "builder_version" => evidence.builder_version, "policy_digest" => evidence.policy_digest,
          "base_images" => evidence.base_images, "layer_digests" => evidence.layer_digests
        ).compact
      end
    end
  end
end
