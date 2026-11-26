module Api
  module V1
    module App
      class WorkflowOutcomeOverridesController < BaseController
        def index
          job = find_job
          candidates = WorkflowOutcomeOverrides::CandidateResolver.for_job(job)
          render json: { candidates: candidates.map { |candidate| candidate.as_json.merge(policy: policy_for(job, candidate).policy) } }
        end

        def create
          job = find_job
          candidate = WorkflowOutcomeOverrides::CandidateResolver.new(job).find!(params.require(:fingerprint_digest))
          decision = policy_for(job, candidate)
          return render_error("outcome_override_denied", t("api.workflow_outcome_overrides.denied"), status: :forbidden) if decision.deny?

          override = WorkflowOutcomeOverrides::Recorder.call(
            job:, fingerprint_digest: candidate.fingerprint.digest, actor: Current.user,
            channel: "ui", reason: params.require(:reason),
            permission_decision: decision.to_h.deep_stringify_keys.merge("confirmation" => "explicit_ui_confirmation")
          )
          WorkflowOutcomeOverrides::Resumer.call(override:)
          render json: { override: { id: override.id, effective_state: override.effective_state } }, status: :created
        rescue WorkflowOutcomeOverrides::CandidateResolver::NotFound => error
          render_error("outcome_override_stale", error.message, status: :conflict)
        rescue WorkflowOutcomeOverrides::Recorder::InvalidRequest, ActionController::ParameterMissing => error
          render_error("outcome_override_invalid", error.message, status: :unprocessable_content)
        rescue WorkflowOutcomeOverrides::Resumer::ResumeFailed => error
          render_error("outcome_override_resume_failed", error.message, status: :conflict)
        end

        private

        def find_job = Job.visible_to(Current.user).find(params[:job_id])

        def policy_for(job, candidate)
          WorkflowOutcomeOverrides::Authority.call(user: Current.user, repository: job.repository, arguments: {
            job_id: job.id, fingerprint_digest: candidate.fingerprint.digest,
            gate_kind: candidate.gate_failure[:gate_kind], gate_identity: candidate.gate_failure[:gate_identity]
          }, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat")
        end
      end
    end
  end
end
