module AgentInsights
  module Proposals
    class CreateJob < Base
      def accept!(actor:, params: {})
        create_job = ActiveModel::Type::Boolean.new.cast(params[:create_job])
        prompt_text = params[:prompt].to_s.strip
        return Result.error("Prompt can't be blank when creating a job.") if create_job && prompt_text.blank?

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
