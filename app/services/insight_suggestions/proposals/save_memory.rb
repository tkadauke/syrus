module InsightSuggestions
  module Proposals
    class SaveMemory < Base
      def accept!(actor:, params: {})
        if ActiveModel::Type::Boolean.new.cast(params[:create_job])
          prompt_text = params[:prompt].to_s.strip
          return Result.error("Prompt can't be blank when creating a job.") if prompt_text.blank?

          return CreateJob.new(suggestion).accept!(actor: actor, params: params)
        end

        Base.accept_suggestion!(suggestion)
      end
    end
  end
end
