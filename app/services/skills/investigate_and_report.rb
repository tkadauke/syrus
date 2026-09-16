module Skills
  # Seed built-in skill for the general investigate-and-report pattern
  # established by the investigation-Jobs Epic: a repeatable, richly
  # instructed launch for QA walkthroughs, audits, and "go check on X
  # and tell me what you find" requests, resolved the same way every
  # other built-in skill is (repo-local override, else built-in, via
  # Skills.for) instead of a hand-rolled prompt each time.
  #
  # Distinct from Skills::Investigate (an older, narrower "answer a
  # question, no tools beyond reading" skill from the skill-workflow
  # feature): this one names the browser/preview/artifact tool access
  # the investigation-Jobs Epic wired up (start_preview/stop_preview,
  # the browser MCP tool set, submit_artifact, submit_visual_artifact)
  # so a launch through the ordinary skill picker or a slash command
  # gets the same evidence-gathering instructions an investigation Job
  # does, without requiring the caller to know that tool list exists.
  class InvestigateAndReport < Base
    def self.skill_name
      "investigate-and-report"
    end

    def self.description
      "Read-only investigation with browser/preview evidence capture: explore the repository (and, when relevant, a live preview) and report findings. Makes no changes and produces no diff."
    end

    def self.parameter_schema
      [
        { key: "request", type: "string", required: true, label: "What to investigate" }
      ]
    end

    def to_s
      <<~INSTRUCTIONS
        You are running a read-only investigation: do not edit, create, or
        delete any files, and do not run commands that mutate the working
        tree or any external system. A thorough, evidence-based answer with
        no code changes is a fully successful outcome -- do not manufacture
        changes just to produce a diff.

        Investigate using read-only tools: read files, search the codebase,
        run `git log`/`git diff`, and run test suites in report-only mode.
        If the request calls for looking at the running app, start a preview
        with `start_preview` and drive it with the browser MCP tools; call
        `stop_preview` when you're done with it. As you gather evidence -- a
        query log, a config dump, a screenshot -- capture it with
        `submit_artifact` (structured data) or `submit_visual_artifact`
        (screenshots) so it's attached to this run.

        Investigation request: {{request}}

        Finish with a clear, direct, evidence-based narrative answering the
        request above. If it cannot be answered from the repository alone,
        say so explicitly instead of guessing.
      INSTRUCTIONS
    end
  end
end
