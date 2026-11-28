module Api
  module V1
    module Admin
      # Restricted evidence for a runtime image build, one entry per finished
      # attempt. This is the only surface that returns build log text and
      # resolved destination addresses; everything else gets the safe summary.
      #
      #   GET /api/v1/admin/runtime_image_build_requests/:id/evidence
      class RuntimeImageBuildEvidencesController < BaseController
        def show
          request_record = RuntimeImageBuildRequest.find(params[:id])
          render json: {
            request_id: request_record.id, state: request_record.state,
            source_digest: request_record.source_digest, recipe_digest: request_record.recipe_digest,
            platform: request_record.platform, result: serialize_result(request_record.result),
            attempts: request_record.evidences.includes(:attempt).map { |evidence| serialize(evidence) },
            verification_policy: serialize_policy_evidence(request_record.result&.runtime_image)
          }
        end

        private

        def serialize_result(result)
          return nil unless result

          result.slice(*%w[outcome digest error_code message attempts_used finished_at]).merge("runtime_image_id" => result.runtime_image_id)
        end

        def serialize(evidence)
          evidence.safe_summary.merge(
            "recipe_digest" => evidence.recipe_digest,
            "policy_snapshot" => evidence.policy_snapshot, "destinations" => evidence.destinations,
            "base_images" => evidence.base_images, "log" => evidence.log
          )
        end

        def serialize_policy_evidence(image)
          attempt = image&.runtime_image_verification_attempts&.order(number: :desc)&.first
          policy_evidence = attempt&.policy_evidence
          scan_evidence = attempt&.scan_evidence
          return nil unless attempt

          (serialize_image_policy(policy_evidence) || {}).merge(
            "attestation" => serialize_attestation(attempt.attestation),
            "supply_chain" => serialize_supply_chain(scan_evidence)
          )
        rescue JSON::ParserError
          (policy_evidence&.slice(*%w[image_digest safe_summary report_digest scanned_at]) || {}).merge(
            "attestation" => serialize_attestation(attempt&.attestation),
            "supply_chain" => scan_evidence&.slice(*%w[image_digest scanner_name scanner_version database_version sbom_digest report_digest finding_summary scanned_at])
          )
        end

        def serialize_attestation(attestation)
          attestation&.slice(*%w[image_digest policy_digest evidence_digest outcome safe_summary vulnerability_database_version issued_at expires_at invalidated_at invalidation_reason exact_evidence_purged_at])
        end

        def serialize_image_policy(evidence)
          return unless evidence

          evidence.slice(*%w[image_digest safe_summary report_digest scanned_at]).merge(
            "report" => evidence.report.attached? ? JSON.parse(evidence.report.download) : nil
          )
        end

        def serialize_supply_chain(evidence)
          return unless evidence

          evidence.slice(*%w[image_digest scanner_name scanner_version database_version sbom_format sbom_digest report_digest finding_summary exemptions decision_evidence scanned_at]).merge(
            "sbom" => evidence.sbom.attached? ? JSON.parse(evidence.sbom.download) : nil,
            "report" => evidence.scan_report.attached? ? JSON.parse(evidence.scan_report.download) : nil
          )
        end
      end
    end
  end
end
