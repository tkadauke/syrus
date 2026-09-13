module AgentInsights
  module Proposals
    class CreateJob < Base
      def accept!(actor:, params: {})
        created_job = nil

        if ActiveModel::Type::Boolean.new.cast(params[:create_job])
          prompt_text = params[:prompt].to_s.strip
          return Result.error("Prompt can't be blank when creating a job.") if prompt_text.blank?

          repository = suggestion.repository
          agent_provider_setting = params[:agent_provider].to_s.presence || Job::ProviderSetting::Base::DEFAULT_VALUE
          agent_provider = Job::ProviderSetting::Base.for(agent_provider_setting).resolve(
            Job.new(repository: repository, user: actor, owner_user: actor)
          )

          created_job = actor.jobs.create!(
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
          created_job.advance_after_triage! if created_job.may_advance_after_triage?
        end

        Base.accept_suggestion!(suggestion, created_job: created_job)
      end
    end
  end
end
