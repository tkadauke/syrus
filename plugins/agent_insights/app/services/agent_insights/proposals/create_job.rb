module AgentInsights
  module Proposals
    class CreateJob < Base
      def accept!(actor:, params: {})
        create_job = ActiveModel::Type::Boolean.new.cast(params[:create_job])
        prompt_text = params[:prompt].to_s.strip
        error = validation_error(actor: actor, params: params)
        return Result.error(error) if error

        created_job = nil
        result = nil

        ApplicationRecord.transaction do
          suggestion.with_lock do
            unless suggestion.pending?
              result = Result.error("Suggestion cannot be accepted (already accepted or dismissed).")
              next
            end

            created_job = build_job!(actor, params, prompt_text) if create_job
            result = Base.accept_suggestion!(suggestion, created_job: created_job)
            raise ActiveRecord::Rollback unless result.ok?
          end
        end

        created_job.advance_after_triage! if result.ok? && created_job&.may_advance_after_triage?
        result
      end

      def validation_error(actor:, params: {})
        return unless ActiveModel::Type::Boolean.new.cast(params[:create_job])
        return "Prompt can't be blank when creating a job." if params[:prompt].to_s.strip.blank?

        setting = params[:agent_provider].to_s.presence || Job::ProviderSetting::Base::DEFAULT_VALUE
        Job::ProviderSetting::Base.for(setting).resolve(
          Job.new(repository: suggestion.repository, user: actor, owner_user: actor)
        )
        nil
      rescue KeyError, ArgumentError => e
        e.message
      end

      def automatic_accept_params
        { create_job: true, prompt: suggestion.suggested_prompt }
      end

      def completed_acceptance_error
        "was accepted without its Job" unless suggestion.created_job
      end

      private

      def build_job!(actor, params, prompt_text)
        repository = suggestion.repository
        agent_provider_setting = params[:agent_provider].to_s.presence || Job::ProviderSetting::Base::DEFAULT_VALUE
        agent_provider = Job::ProviderSetting::Base.for(agent_provider_setting).resolve(
          Job.new(repository: repository, user: actor, owner_user: actor)
        )

        actor.jobs.create!(
          repository: repository,
          kind: "direct",
          issue_number: nil,
          issue_title: suggestion.title.truncate(120),
          title_pending: false,
          issue_body: prompt_text,
          agent_provider: agent_provider,
          job_provider_setting: agent_provider_setting,
          priority: "medium",
          state: Job.initial_state_for_creator(actor)
        )
      end
    end
  end
end
