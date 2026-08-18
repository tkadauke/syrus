module Skills
  # Built-in skill (EPIC-234): read-only, plain-language digest of why CI
  # is currently failing on a Job's pull request. No fix attempt, no
  # working-tree changes — distinct from the `ci_failure` trigger kind's
  # automated `analyze_and_fix` repair loop, which this does not touch.
  # For when an operator wants to understand a failure without triggering
  # an automatic patch.
  #
  # A skill Job is always a fresh `direct` Job with no PR of its own (see
  # SkillJobs::Creator), so it can't infer "the failing PR" from itself —
  # it needs the *target* Job (the one with the failing PR) as a launch
  # parameter. The agent sandbox also has no GitHub API credentials of its
  # own (only git push access to the branch it commits to), so the
  # check-run data has to be fetched here, Ruby-side, before the agent
  # turn starts — mirroring how Skills::OnboardToSyrus's pre-scan runs
  # Ruby-side against a real on-disk checkout. The fetch reuses
  # CiRepair::CheckRefresh (the same data `refresh_pr_checks`/
  # `mergeability_preflight` already read) and CiRepair::FailureDigest
  # (structured per-check context via CiRepair::CheckEnricher) rather than
  # re-implementing check/log retrieval.
  #
  # That live fetch only happens when the resolver has the submitted args
  # and a repository in hand — currently only Steps::RunSkill supplies
  # both (see Skills::Base, Skills.for). The picker/chat-slash-command/
  # ScheduledTask paths fall back to generic instructions with no digest,
  # the same existing limitation Skills::OnboardToSyrus's workspace-less
  # paths already have.
  class ExplainFailingCi < Base
    def self.skill_name
      "explain-failing-ci"
    end

    def self.description
      "Read-only digest of why CI is failing on a Job's pull request. Explains the failure; attempts no fix and makes no changes."
    end

    def self.parameter_schema
      [
        { key: "job_id", type: "integer", required: true, label: "Job with failing CI" }
      ]
    end

    def to_s
      [ intro, digest_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    def job_id
      Integer(@args["job_id"])
    rescue ArgumentError, TypeError
      nil
    end

    def target_job
      return nil unless job_id && @repository

      @target_job ||= @repository.jobs.find_by(id: job_id)
    end

    def intro
      <<~TXT.strip
        You are writing a plain-language digest of why CI is currently
        failing on another Job's pull request. This is a read-only report:
        do not edit, create, or delete any files, do not attempt a fix, and
        do not commit anything. Your task is to explain the failure, not to
        repair it.

        Target Job: {{job_id}}
      TXT
    end

    def digest_section
      return nil unless job_id && @repository

      <<~TXT.strip
        ## Automated pre-fetch results

        Syrus already fetched this Job's current GitHub check-run state
        before invoking you — the same fetch the `ci_failure` repair flow
        and the landing preflight use — because this sandbox has no GitHub
        API credentials of its own. Use it as your source of truth rather
        than trying to reach GitHub yourself.

        #{digest_body}
      TXT
    end

    def digest_body
      job = target_job
      return "Job ##{job_id} was not found in this repository. Report that you could not find the target Job and stop." unless job

      pr_number = job.pr_number || job.external_pr_number
      return "Job ##{job.id} (#{job.slug}) has no associated pull request to check. Report that and stop." if pr_number.blank?

      begin
        result = CiRepair::CheckRefresh.call(job)
      rescue StandardError => e
        return "Could not fetch CI status for Job ##{job.id} (#{job.slug}): #{e.class}: #{e.message}. " \
          "Report the failure and stop."
      end

      CiRepair::FailureDigest.call(result)
    end

    def step_by_step_instructions
      <<~TXT.strip
        ## What to do

        Read the pre-fetched CI status above and write a clear,
        plain-language explanation of what failed and why, suitable for an
        operator who has not looked at the raw logs. Where the structured
        error context names specific failing tests, offenses, or an error
        block, ground your explanation in those specifics rather than
        restating the check name.

        Do not propose or make a fix. Do not edit any files. Do not commit
        anything — this skill always ends with no diff, which is the
        correct, successful outcome: it closes without opening a PR. Write
        your explanation as your final report.
      TXT
    end
  end
end
