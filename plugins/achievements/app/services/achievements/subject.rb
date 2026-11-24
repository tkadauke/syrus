module Achievements
  # A weak reference to the thing an unlock is about, built from event ids.
  # Evaluation works from domain-event primitives, never core model instances.
  Subject = Data.define(:kind, :id)
end
