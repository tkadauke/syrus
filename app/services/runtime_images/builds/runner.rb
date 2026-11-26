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

      def initialize(orchestrator: Orchestrator.new, service: Service.new, builder: nil, recorder: EvidenceRecorder.new,
                     base_verifier: ConformanceProbe.method(:verify_published!), candidate_probe: Verifications::CandidateProbe.new)
        @base_verifier = base_verifier
        @candidate_probe = candidate_probe
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
        failure = classify_build_failure(e, evidence)
        @orchestrator.fail_attempt(attempt, **failure)
      rescue RuntimeImages::ProviderError, ActiveRecord::ConnectionNotEstablished, Timeout::Error, SystemCallError => e
        # Registry and infrastructure trouble is transient by nature, but a
        # full quota or an unreachable registry needs its own, slower backoff.
        @orchestrator.fail_attempt(attempt, code: infrastructure_code(e), detail: "#{e.class}: #{e.message}", retryable: true)
      rescue StandardError => e
        @orchestrator.fail_attempt(attempt, code: "unexpected_error", detail: "#{e.class}: #{e.message}", retryable: false)
      ensure
        # Every terminal path leaves evidence bound to the attempt's outcome.
        @recorder.record(request: request, attempt: attempt, evidence: evidence) if evidence
      end

      QUOTA_PATTERN = /quota|too\s*many\s*requests|toomanyrequests|\b429\b|storage limit|rate limit|limit exceeded/i

      private

      # A build that failed while the egress proxy refused destinations did not
      # fail for a reason a retry can fix: the allowlist has to change first.
      # The detail carries only counts and reasons; hosts stay in the
      # administrator-only evidence.
      def classify_build_failure(error, evidence)
        failure = { code: error.code, detail: error.message, retryable: error.retryable }
        denials = evidence.denials
        return failure if denials.empty? || error.code != "build_failed"

        reasons = denials.map { |entry| entry["reason"] }.compact.uniq.sort.join(", ")
        { code: "network_denied", retryable: false,
          detail: "build failed after #{denials.sum { |entry| entry["count"].to_i }} refused network request(s) (#{reasons}); " \
                  "review the build-network allowlist" }
      end

      def infrastructure_code(error)
        return "quota_exhausted" if error.is_a?(Errno::ENOSPC) || error.is_a?(Errno::EDQUOT)
        return "quota_exhausted" if error.is_a?(RuntimeImages::ProviderError) && error.message.match?(QUOTA_PATTERN)
        return "registry_unavailable" if error.is_a?(RuntimeImages::ProviderError)

        "infrastructure_error"
      end

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
          provenance: provenance_for(request, output, evidence), payload: output.payload, verification_state: "unverified"
        )
        evidence.image_digest = image.digest
        verification = verify_candidate(request, image)
        unless verification.accepted?
          retryable = verification.state == "blocked"
          raise BuildFailed.new(verification.message || "image verification #{verification.state}",
                                code: verification.failure_code || "verification_failed", retryable: retryable)
        end
        register_base_release(request, image)
        image
      end

      def verify_candidate(request, image)
        registry = Verifications::Registry.new
        registry.register("manifest", Verifications::ManifestVerifier.new(service: @service))
        policy = Verifications::Orchestrator::DEFAULT_POLICY.deep_dup
        if request.source_kind == CoworkerBase::SOURCE_KIND
          registry.register("base_conformance", Verifications::CallableVerifier.new(@base_verifier, evidence_kind: "confined_conformance_probe"))
          policy["checks"] << { "key" => "base_conformance", "required" => true }
        end
        verification = Hash(request.recipe.dig("input_policy"))
        if verification["base_digest"].present? && verification["smoke_test"].present?
          suite = Verifications::CandidateSuite.new(@candidate_probe)
          Verifications::CandidateSuite.check_keys.each do |key|
            registry.register(key, Verifications::CandidateVerifier.new(suite, key))
            policy["checks"] << { "key" => key, "required" => true }
          end
        end
        Verifications::Orchestrator.new(registry: registry, service: @service).verify(image, policy: policy, context: { build_request_id: request.id })
      end

      # A verified standard base becomes a promotion candidate. It is never
      # active until an operator promotes it.
      def register_base_release(request, image)
        return unless request.source_kind == CoworkerBase::SOURCE_KIND

        BaseReleases.new(service: @service).register(image)
      end

      # Builder-reported provenance plus the bindings that make the image
      # traceable to its inputs. Safe to store on the image: digests and names
      # only, never log text or resolved addresses.
      def provenance_for(request, output, evidence)
        provenance = Hash(output.provenance).merge(
          "build_request_id" => request.id, "recipe_digest" => request.recipe_digest,
          "builder_version" => evidence.builder_version, "policy_digest" => evidence.policy_digest,
          "base_images" => evidence.base_images, "layer_digests" => evidence.layer_digests
        ).compact
        # Syrus (never the isolated builder, which holds no key) signs the
        # runtime ABI contract the standard base was built against.
        input_policy = Hash(request.recipe.dig("input_policy"))
        if request.source_kind == CoworkerBase::SOURCE_KIND || input_policy["runtime_abi"].present?
          provenance[RuntimeAbi::ATTESTATION_KEY] = RuntimeAbi.attest(
            source_digest: request.source_digest, recipe_digest: request.recipe_digest, build_request_id: request.id
          )
        end
        provenance
      end
    end
  end
end
