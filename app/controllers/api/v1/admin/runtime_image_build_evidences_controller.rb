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
            verification_policy: serialize_verification_evidence(request_record.result&.runtime_image)
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

        def serialize_verification_evidence(image)
          attempt = image&.runtime_image_verification_attempts&.order(number: :desc)&.first
          return nil unless attempt

          policy = attempt.policy_evidence
          scan = attempt.scan_evidence
          attempt.slice(*%w[image_digest policy_digest evidence_digest attestation_digest expires_at]).merge(
            "safe_summary" => { "policy" => policy&.safe_summary, "supply_chain" => scan&.finding_summary }.compact,
            "policy_report_digest" => policy&.report_digest,
            "policy_report" => attached_json(policy&.report),
            "scan_report_digest" => scan&.report_digest,
            "scan_report" => attached_json(scan&.scan_report)
          )
        rescue JSON::ParserError
          attempt.slice(*%w[image_digest policy_digest evidence_digest attestation_digest expires_at])
        end


        def attached_json(attachment)
          attachment&.attached? ? JSON.parse(attachment.download) : nil
        end
      end
    end
  end
end
