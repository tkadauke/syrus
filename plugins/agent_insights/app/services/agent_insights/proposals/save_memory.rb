module AgentInsights
  module Proposals
    class SaveMemory < Base
      def accept!(actor:, params: {})
        if ActiveModel::Type::Boolean.new.cast(params[:create_job])
          prompt_text = params[:prompt].to_s.strip
          return Result.error("Prompt can't be blank when creating a job.") if prompt_text.blank?

          return CreateJob.new(suggestion).accept!(actor: actor, params: params)
        end

        if ActiveModel::Type::Boolean.new.cast(params[:save_memory])
          return Result.error("No memory suggestion available.") if suggestion.memory_suggestion.blank?

          memory = AgentMemory::Entry.create!(
            user: actor, kind: "project_fact", scope: "repository", scope_id: suggestion.repository_id,
            content: suggestion.redacted_memory_suggestion, source_type: "insight", source_id: suggestion.id,
            author: "agent", confidence: suggestion.confidence
          )
          result = Base.accept_suggestion!(suggestion)
          return Result.ok(message: "Memory saved and suggestion accepted.", suggestion: result.suggestion, memory: memory) if result.ok?

          raise ActiveRecord::Rollback
        end

        Base.accept_suggestion!(suggestion)
      end

      def validation_error(actor:, params: {})
        return "No memory suggestion available." if ActiveModel::Type::Boolean.new.cast(params[:save_memory]) && suggestion.memory_suggestion.blank?

        nil
      end

      def automatic_accept_params
        { save_memory: true }
      end

      def completed_acceptance_error
        "was accepted without its memory" unless accepted_memory
      end

      def accepted_memory
        AgentMemory::Entry.find_by(source_type: "insight", source_id: suggestion.id)
      end
    end
  end
end
