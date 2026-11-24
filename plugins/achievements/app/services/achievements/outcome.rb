module Achievements
  # What an evaluator decided: unlock for this owner, about this subject.
  Outcome = Data.define(:user_id, :subject, :evidence)
end
