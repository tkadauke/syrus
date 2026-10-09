require "json"

module Prompts
  # GitHub-sourced content trust boundary
  class IngestionClassifier
    include GithubContentTrust

    def initialize(job:, epics:, merged_pull_requests:, duplicate_candidates:, repository_capabilities: {})
      @job = job
      @epics = epics
      @merged_pull_requests = merged_pull_requests
      @duplicate_candidates = duplicate_candidates
      @repository_capabilities = repository_capabilities
    end

    def to_s
      <<~PROMPT
        #{github_content_trust_boundary}

        You are classifying a newly-ingested GitHub issue before Syrus queues implementation work.

        Decide whether the issue strongly belongs to an existing Epic, is an obvious duplicate of an existing open Job, is already implemented by a recently merged PR, or is novel. Also choose a conservative primary implementation placement when the request clearly needs one.

        Use conservative judgment:
        - Set epic_id only when the issue clearly belongs to that Epic.
        - Mark duplicate only when the requested work substantially matches an open Job candidate.
        - Mark already_implemented only when a merged PR appears to have already shipped the requested behavior.
        - For backend-only work, leave planned_execution null so Syrus uses default Linux compute.
        - For iOS, mobile Apple, or Xcode-targeted work, set planned_execution capabilities to {"os":["macos"],"arch":["arm64"],"toolchain":["xcode"],"runtime":["ios_simulator"]}.
        - For mixed iOS and backend work, choose macos as the primary implementation placement; backend graders can run elsewhere later.
        - Supported dimensions are os, arch, toolchain, and runtime. There is no Windows value; leave planned_execution null for Windows-targeted work so it takes the Linux default unless the operator explicitly chooses a supported host.
        - An issue naming several platforms is not a conflict: nothing reads the issue text to pick a host, so either name the host the implementation needs or leave planned_execution null for the Linux default.
        - Otherwise return nulls so normal triage can continue.

        Evidence requirements:
        - duplicate: evidence_urls must include the matching candidate Job/issue URL.
        - already_implemented: evidence_urls must include the merged PR URL, and reason must be one sentence summarizing why that PR covers the issue.

        Return ONLY compact JSON with this exact shape:
        {"epic_id":null,"invalid":{"kind":null,"reason":"","evidence_urls":[]},"planned_execution":null}

        New issue:
        #{JSON.pretty_generate(issue_payload)}

        Recent open Epics:
        #{JSON.pretty_generate(@epics)}

        Recent merged PRs in this repository:
        #{JSON.pretty_generate(@merged_pull_requests)}

        Similar open Jobs:
        #{JSON.pretty_generate(@duplicate_candidates)}

        Repository capability metadata:
        #{JSON.pretty_generate(@repository_capabilities)}
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
