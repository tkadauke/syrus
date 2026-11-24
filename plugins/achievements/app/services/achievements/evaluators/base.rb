module Achievements
  module Evaluators
    # An evaluator answers "does this event earn this definition?" with an
    # Outcome or nil. It never writes; Evaluation records the outcome through
    # Unlock.record!, which is what makes repeated delivery harmless.
    class Base
      def call(definition, adapter)
        return nil unless adapter.completed?
        return nil unless definition.subject_kinds.include?(adapter.subject.kind)

        user_id = adapter.attributed_user_id
        # A per-user accomplishment with nobody to credit is not awarded; an
        # instance milestone never carries a user.
        return nil if definition.user_scoped? && user_id.nil?
        return nil unless earned?(definition, adapter)

        Outcome.new(user_id: definition.user_scoped? ? user_id : nil, subject: adapter.subject, evidence: adapter.evidence)
      end

      private

      def earned?(_definition, _adapter) = raise(NotImplementedError)
    end
  end
end
