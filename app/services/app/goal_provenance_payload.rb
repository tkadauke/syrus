module App
  module GoalProvenancePayload
    module_function

    def for(record)
      goal_id = record&.chat_goal_id
      return nil if goal_id.blank?

      {
        chat_goal_id: goal_id,
        prompt_snapshot: record.goal_prompt_snapshot || {}
      }
    end
  end
end
