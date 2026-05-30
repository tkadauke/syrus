module Steps
  # Compatibility handler for the historical apply_suggestions step kind.
  # Current grade loops feed grader failures back into the next implement
  # iteration, but old Workflow rows and the Step registry can still refer
  # to this kind.
  class ApplySuggestions < Base
    def call
      log("[apply_suggestions] no-op: grader feedback is applied by the next implement iteration", kind: "system")
    end
  end
end
