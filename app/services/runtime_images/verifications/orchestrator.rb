module RuntimeImages
  module Verifications
    class Orchestrator
      ATTEMPT_NUMBER_RETRIES = 3
      DEFAULT_POLICY = {
        "version" => 1,
        "checks" => [ { "key" => "manifest", "required" => true }, { "key" => "supply_chain", "required" => true } ],
        "vulnerabilities" => { "blocked_severities" => %w[critical high] },
        "prohibited_packages" => [],
        "exemptions" => [],
        "block_secrets" => true,
        "block_prohibited_packages" => true,
        "block_policy_violations" => true,
        "image" => { "max_bytes" => 2.gigabytes, "max_layers" => 128, "required_user" => "1000",
                     "required_entrypoint" => [], "required_command" => [ "/bin/bash" ], "forbidden_capabilities" => [ "ALL" ] }
      }.freeze

      def initialize(registry: nil, service: Service.new, supply_chain_scanner: nil, image_policy_scanner: nil)
        @registry = registry || default_registry(service, supply_chain_scanner, image_policy_scanner)
      end

      # Every call is a new durable attempt. This is also the re-verification
      # path: prior evidence remains immutable and the latest decision alone
      # controls candidate eligibility.
      def verify(image, policy: DEFAULT_POLICY, context: {}, now: Time.current)
        attempt_number_retries = 0
        begin
          snapshot = canonical(policy)
          attempt = create_attempt(image, snapshot, now)
          checks = Array(snapshot.fetch("checks"))
          checks = [ { "key" => "policy_checks_missing", "required" => true } ] if checks.empty?
          checks.each_with_index { |definition, position| run_check(attempt, definition, position, context, now) }
          finish(attempt, now)
        rescue ActiveRecord::RecordNotUnique
          attempt_number_retries += 1
          retry if attempt_number_retries <= ATTEMPT_NUMBER_RETRIES
          raise
        end
      end

      private

      def default_registry(service, supply_chain_scanner, image_policy_scanner)
        scanner = supply_chain_scanner || SupplyChainScanner.new(built_images: BuiltImages.new(service: service))
        Registry.new.tap do |registry|
          registry.register("manifest", ManifestVerifier.new(service: service))
          registry.register("supply_chain", SupplyChainVerifier.new(scanner: scanner))
          registry.register("image_policy", ImagePolicyVerifier.new(scanner: image_policy_scanner || ImagePolicyScanner.new(built_images: BuiltImages.new(service: service))))
        end
      end

      def create_attempt(image, snapshot, now)
        image.with_lock do
          image.update!(verification_state: "unverified")
          RuntimeImageVerificationAttempt.create!(
            runtime_image: image, number: image.runtime_image_verification_attempts.maximum(:number).to_i + 1,
            image_digest: image.digest, state: "running", policy_snapshot: snapshot,
            policy_digest: "sha256:#{Digest::SHA256.hexdigest(JSON.generate(snapshot))}", started_at: now
          )
        end
      end

      def run_check(attempt, definition, position, context, now)
        definition = Hash(definition).stringify_keys
        check = attempt.checks.create!(position: position, verifier_key: definition.fetch("key"), required: definition.fetch("required", true), state: "running", started_at: now)
        verifier = @registry.fetch(check.verifier_key)
        result = verifier&.call(image: attempt.runtime_image, policy: attempt.policy_snapshot, context: context, attempt: attempt)
        result ||= Result.fail(failure_class: :infrastructure, code: :verifier_unavailable, message: "required verifier #{check.verifier_key} is unavailable")
        result = Result.fail(failure_class: :evidence, code: :evidence_unavailable, message: "verifier produced no durable evidence") if result.passed? && result.evidence_references.empty?
        check.update!(state: result.passed? ? "passed" : (result.failure_class == "infrastructure" ? "unavailable" : "failed"),
                      failure_class: result.failure_class, failure_code: result.code, message: result.message.to_s.truncate(500).presence,
                      evidence_references: result.evidence_references, finished_at: Time.current)
      rescue StandardError => e
        check&.update!(state: "unavailable", failure_class: "verifier", failure_code: "verifier_error",
                       message: "#{e.class}: #{e.message}".truncate(500), evidence_references: [], finished_at: Time.current)
      end

      def finish(attempt, now)
        failure = attempt.checks.where(required: true).where.not(state: "passed").order(:position).first
        image = attempt.runtime_image
        image.with_lock do
          if failure
            blocked = %w[infrastructure evidence verifier].include?(failure.failure_class)
            state = blocked ? "blocked" : "rejected"
            attempt.update!(state: state, decision: state, failure_class: failure.failure_class,
                            failure_code: failure.failure_code, message: failure.message, finished_at: now)
          else
            attempt.update!(state: "accepted", decision: "candidate", finished_at: now)
          end
          # A slower, older re-verification must never overwrite the decision
          # of a newer attempt for the same immutable digest.
          if image.runtime_image_verification_attempts.maximum(:number) == attempt.number
            image.update!(verification_state: attempt.accepted? ? "candidate" : attempt.state)
          end
        end
        attempt
      end

      def canonical(value)
        case value
        when Hash
          value.stringify_keys.sort.to_h { |key, item| [ key, canonical(item) ] }
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end
    end
  end
end
