module Skills
  # Seed built-in skill (EPIC-233): a read-only investigation that
  # answers a question about the repository. No diff, no commit — exists
  # so later Jobs in this Epic (skill Job/Workflow kind, chat slash
  # command, ScheduledTask launch) have a real built-in to exercise
  # end-to-end.
  class Investigate < Base
    def self.skill_name
      "investigate"
    end

    def self.description
      "Read-only investigation that answers a question about the repository. Makes no changes and produces no diff."
    end

    def self.parameter_schema
      [
        { key: "question", type: "string", required: true, label: "Question" }
      ]
    end

    def to_s
      <<~INSTRUCTIONS
        You are answering a specific question about this repository. This is a
        read-only investigation: do not edit, create, or delete any files, and
        do not run commands that mutate the working tree or any external
        system.

        Question: {{question}}

        Investigate using read-only tools (reading files, searching, `git
        log`, `git diff`, running test suites in report-only mode, etc.) and
        produce a clear, direct answer. If the question cannot be answered
        from the repository alone, say so explicitly instead of guessing.
      INSTRUCTIONS
    end
  end
end
