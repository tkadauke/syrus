module Skills
  # Built-in skill backing the general investigate-and-report pattern
  # (EPIC-361): a read-only exploration that ends in an evidence-backed
  # narrative report instead of a pull request -- QA walkthroughs, audits,
  # "go check on X and tell me what you find" requests. Steps::Investigate
  # resolves this skill the same way Steps::RunSkill resolves any other
  # (repo-local override, else this built-in), so a repository can tailor
  # its own investigation instructions via `.syrus/skills/investigate-and-report/SKILL.md`
  # instead of the boilerplate being hand-rolled in Prompts::Investigation.
  #
  # Distinct from Skills::Investigate (the plain read-only Q&A skill
  # launched through the unrelated `skill` Job kind / Workflows::Skill) --
  # this one backs `investigation`-flagged direct Jobs and their
  # `prepare -> investigate -> submit_report -> auto_close` chain, so its
  # instructions point at the report-producing tools (submit_artifact,
  # submit_visual_artifact) that step expects evidence to already be
  # captured for.
  class InvestigateAndReport < Base
    def self.skill_name
      "investigate-and-report"
    end

    def self.description
      "General investigate-and-report pattern: a read-only exploration of the repository (and, where " \
        "relevant, its running app) that ends in an evidence-backed narrative report instead of a pull " \
        "request. Backs investigation Jobs -- QA walkthroughs, audits, and 'go check on X and tell me what " \
        "you find' requests."
    end

    def self.parameter_schema
      [
        { key: "request", type: "text", required: true, label: "Investigation request" }
      ]
    end

    def to_s
      <<~INSTRUCTIONS
        You are running an investigation-only Job: no pull request is
        expected, and there is no requirement to change any code. Explore
        the repository -- read files, search, run tests -- and answer the
        request below with a clear, evidence-based narrative. A thorough
        answer with no code changes is a fully successful outcome; do not
        manufacture changes just to produce a diff.

        If the request calls for looking at the running app, start a
        preview with `start_preview` and drive it with the browser tools;
        call `stop_preview` when you're done with it. As you gather
        evidence -- a query log, a config dump, a screenshot -- capture it
        with `submit_artifact` (structured data) or `submit_visual_artifact`
        (screenshots) so it's attached to this run. Note the exact
        artifact `type` each call reports back; the follow-up report step
        can point at that evidence by `type`, in the order that best
        supports your narrative.

        Investigation request:

        {{request}}
      INSTRUCTIONS
    end
  end
end
