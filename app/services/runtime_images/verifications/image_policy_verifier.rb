module RuntimeImages
  module Verifications
    class ImagePolicyVerifier
      def initialize(scanner: ImagePolicyScanner.new)
        @scanner = scanner
      end

      def call(image:, policy:, context:, attempt:, **)
        request = RuntimeImageBuildRequest.find(context.fetch(:build_request_id))
        evidence = context.fetch(:build_evidence)
        report = @scanner.call(image: image, request: request, evidence: evidence)
        findings = findings_for(report, policy, evidence)
        record = persist(attempt, report, findings)
        reference = { "kind" => "restricted_image_policy", "id" => record.id, "digest" => image.digest,
                      "report_digest" => record.report_digest }
        return Result.pass(evidence_references: [ reference ]) if findings.empty?

        Result.fail(failure_class: :policy, code: findings.first.fetch("code"),
                    message: "Image policy rejected #{findings.size} finding(s); restricted remediation evidence is available to administrators.",
                    evidence_references: [ reference ])
      rescue KeyError, ActiveRecord::RecordNotFound, ProviderError, Builds::Rejected, Timeout::Error, SystemCallError => e
        Result.fail(failure_class: :infrastructure, code: :image_policy_unavailable,
                    message: "image policy verification unavailable: #{e.class}")
      end

      private

      def findings_for(report, policy, evidence)
        config = Hash(policy["image"])
        metadata = Hash(report.metadata)
        rootfs = Hash(metadata["RootFS"])
        layers = Array(rootfs["Layers"])
        size = metadata["Size"].to_i
        user = metadata.dig("Config", "User").to_s.split(":", 2).first
        entrypoint = Array(metadata.dig("Config", "Entrypoint"))
        command = Array(metadata.dig("Config", "Cmd"))
        capabilities = metadata.dig("Config", "Labels", "io.syrus.requested-capabilities").to_s.split(",").map(&:strip)
        findings = []
        findings << finding("image_too_large", "metadata") if size > config.fetch("max_bytes").to_i
        findings << finding("too_many_layers", "layers") if layers.size > config.fetch("max_layers").to_i
        findings << finding("invalid_user", "metadata") if user != config.fetch("required_user").to_s
        findings << finding("invalid_entrypoint", "metadata") unless entrypoint == Array(config.fetch("required_entrypoint")) &&
          command == Array(config.fetch("required_command"))
        findings << finding("forbidden_capability", "metadata") if (capabilities & Array(config["forbidden_capabilities"])).any?
        findings << finding("build_destination_not_allowlisted", "build_network") unless destinations_allowed?(evidence)
        secret_count = Array(Hash(report.secrets)["Results"]).sum { |result| Array(result["Secrets"]).size }
        findings.concat(Array.new(secret_count) { finding("secret_detected", "restricted") })
        findings
      end

      def destinations_allowed?(evidence)
        policy = BuildNetwork::Policy.new(Array(evidence.policy_snapshot).map do |rule|
          BuildNetwork::Policy::Rule.new(**Hash(rule).symbolize_keys.slice(*BuildNetwork::Policy::Rule.members))
        end)
        Array(evidence.destinations).all? do |destination|
          policy.decide(host: destination["host"], port: destination["port"].to_i, path: destination["path"]).allowed?
        end
      rescue KeyError, ArgumentError
        false
      end

      def finding(code, source) = { "code" => code, "source" => source }

      def persist(attempt, report, findings)
        payload = JSON.generate("metadata" => report.metadata, "history" => report.history,
                                "secret_scan" => report.secrets, "findings" => findings)
        record = attempt.create_policy_evidence!(image_digest: attempt.image_digest,
          safe_summary: { "finding_count" => findings.size, "codes" => findings.pluck("code").tally.sort.to_h },
          report_digest: "sha256:#{Digest::SHA256.hexdigest(payload)}", scanned_at: report.scanned_at)
        record.report.attach(io: StringIO.new(payload), filename: "image-policy-#{attempt.image_digest.delete_prefix('sha256:')}.json",
                             content_type: "application/json")
        record
      end
    end
  end
end
