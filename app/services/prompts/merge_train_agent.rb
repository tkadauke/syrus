module Prompts
  class MergeTrainAgent
    def initialize(train:, workflow:, failing_round:)
      @train = train
      @workflow = workflow
      @failing_round = failing_round.to_h
    end

    def to_s
      [
        context_section,
        failure_section,
        action_contract_section,
        GitSafety::TEXT
      ].join("\n\n---\n\n")
    end

    private

    def context_section
      <<~SECTION.strip
        This is a bounded merge-train agent rung for `#{@train.repository.slug}`.

        Syrus already assembled integration branch `#{@train.integration_branch}` from base branch `#{@train.base_branch}` and ran the normal landing repair loop. That loop did not produce a green grading result, so you get one bounded pass to preserve as much landable work as possible.

        Members:
        #{member_lines.join("\n")}
      SECTION
    end

    def member_lines
      @train.members.includes(:job).map do |member|
        job = member.job
        pr = job.pr_number ? "PR ##{job.pr_number}" : "no PR"
        "- #{job.slug}: #{job.title} (#{pr}, branch `#{job.branch_name}`, train position #{member.position})"
      end
    end

    def failure_section
      grader_results = Array(@failing_round["grader_results"]).map do |result|
        tests = Array(result["failed_tests"]).filter_map { |test| test["identity"].presence || test["name"].presence }
        "- #{result['name'] || 'grader'}: #{tests.presence&.join(', ') || result['output'].to_s.truncate(300)}"
      end

      <<~SECTION.strip
        Current failing identities:
        #{Array(@failing_round["failing_set"]).presence&.map { |item| "- #{item}" }&.join("\n") || "- (none recorded)"}

        Failed grader summary:
        #{grader_results.presence&.join("\n") || "- (no grader summary recorded)"}
      SECTION
    end

    def action_contract_section
      <<~SECTION.strip
        Authority:
        - You may repair the integration branch in place, make focused ordering or integration edits, and run targeted checks.
        - You may withdraw one suspected culprit only if the evidence is specific enough to name the member. Withdrawing clears that Job's approval and stops this train; Syrus will rederive any remaining train from the approved pool.
        - You do not decide to merge. After a repair, Syrus will run prepare and the normal graders again before any landing step is reachable.
        - Do not delete or weaken tests to make the grader green. Fix the work, or withdraw the culprit.
        - Keep the attempt bounded. If the evidence is insufficient, make no speculative changes and report that you could not safely act.

        Durable action record:
        Write `.syrus/merge_train_agent.json` with exactly one of these shapes before you finish:

        Repair:
        {
          "action": "repair",
          "evidence": "why this repair addresses the failing set",
          "changes": "what changed on the integration branch"
        }

        Withdraw:
        {
          "action": "withdraw",
          "job_slug": "JOB-123",
          "evidence": "why this member is the culprit"
        }

        No progress:
        {
          "action": "no_progress",
          "evidence": "why no safe repair or withdrawal was available"
        }
      SECTION
    end
  end
end
