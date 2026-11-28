module Api
  module V1
    module Admin
      # GET /api/v1/admin/invariants -- evaluates the invariant monitor live
      # and returns every current violation, annotated with when the periodic
      # monitor first recorded it.
      #
      #   ?only=retry_storms,slot_holders  evaluate only these invariants
      #   ?job_id=123,456                  evaluate only these Jobs' records
      #   ?include_resolved=true           also list recently resolved episodes
      class InvariantsController < BaseController
        RESOLVED_LIMIT = 50

        def index
          report = Invariants.evaluate(now: Time.current, scope: scope_param, only: only_param)
          records = InvariantViolation.open.where(fingerprint: report.violations.map(&:fingerprint)).index_by(&:fingerprint)

          payload = report.as_json
          payload[:ok] = report.ok?
          payload[:violations] = report.violations.map do |violation|
            record = records[violation.fingerprint]
            violation.as_json.merge(
              first_detected_at: record&.first_detected_at&.iso8601,
              last_detected_at: record&.last_detected_at&.iso8601,
              detection_count: record&.detection_count || 0
            )
          end
          if truthy?(params[:include_resolved])
            payload[:recently_resolved] = InvariantViolation.resolved.order(resolved_at: :desc, id: :desc).limit(RESOLVED_LIMIT).map(&:as_json)
          end

          render json: payload
        rescue Invariants::UnknownInvariant => e
          render_error(
            "unknown_invariant",
            I18n.t("api.admin.invariants.unknown_invariant", key: e.message, known: Invariants.keys.join(", ")),
            status: :bad_request
          )
        end

        private

        def only_param
          keys = params[:only].to_s.split(",").map(&:strip).reject(&:blank?)
          keys.presence
        end

        def scope_param
          ids = params[:job_id].to_s.split(",").map(&:strip).reject(&:blank?)
          ids.empty? ? Invariants::Scope.all : Invariants::Scope.for_jobs(ids)
        end
      end
    end
  end
end
