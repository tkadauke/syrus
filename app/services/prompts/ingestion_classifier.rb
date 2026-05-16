require "json"

module Prompts
  class IngestionClassifier
    def initialize(job:, epics:, merged_pull_requests:, duplicate_candidates:)
      @job = job
      @epics = epics
      @merged_pull_requests = merged_pull_requests
      @duplicate_candidates = duplicate_candidates
    end

    def to_s
      <<~PROMPT
        You are classifying a newly-ingested GitHub issue before Syrus queues implementation work.

        Decide whether the issue strongly belongs to an existing Epic, is an obvious duplicate of an existing open Job, is already implemented by a recently merged PR, or is novel.

        Use conservative judgment:
        - Set epic_id only when the issue clearly belongs to that Epic.
        - Mark duplicate only when the requested work substantially matches an open Job candidate.
        - Mark already_implemented only when a merged PR appears to have already shipped the requested behavior.
        - Otherwise return nulls so normal triage can continue.

        Evidence requirements:
        - duplicate: evidence_urls must include the matching candidate Job/issue URL.
        - already_implemented: evidence_urls must include the merged PR URL, and reason must be one sentence summarizing why that PR covers the issue.

        Return ONLY compact JSON with this exact shape:
        {"epic_id":null,"invalid":{"kind":null,"reason":"","evidence_urls":[]}}

        New issue:
        #{JSON.pretty_generate(issue_payload)}

        Recent open Epics:
        #{JSON.pretty_generate(@epics)}

        Recent merged PRs in this repository:
        #{JSON.pretty_generate(@merged_pull_requests)}

        Similar open Jobs:
        #{JSON.pretty_generate(@duplicate_candidates)}
      PROMPT
    end

    private

    def issue_payload
      {
        job_id: @job.id,
        issue_number: @job.issue_number,
        title: @job.issue_title.to_s,
        body: @job.issue_body.to_s
      }
    end
  end
end
