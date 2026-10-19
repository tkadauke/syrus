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

        Decide whether the issue strongly belongs to an existing Epic, is an obvious duplicate of an existing open Job, is already implemented by a recently merged PR, or is novel. You may also recommend a validated execution profile. The recommendation is advisory and an operator must confirm any non-Linux placement.

        Use conservative judgment:
        - Set epic_id only when the issue clearly belongs to that Epic.
        - Mark duplicate only when the requested work substantially matches an open Job candidate.
        - Mark already_implemented only when a merged PR appears to have already shipped the requested behavior.
        - For ordinary backend, web, Electron, or JavaScript work, leave placement_recommendation null so Syrus uses default Linux compute.
        - The only profile values are linux, macos_desktop, and ios_xcode. Never invent capabilities.
        - macos_desktop is for work that must build or test a desktop macOS application. It does not include Xcode or an iOS simulator.
        - ios_xcode is only for iOS, Apple mobile, or Xcode-targeted work.
        - Mentioning macOS, Squirrel, or Electron does not by itself justify ios_xcode.
        - For mixed iOS and backend work, recommend ios_xcode as the primary implementation placement; backend graders can run elsewhere later.
        - For Windows-targeted work, leave placement_recommendation null so it takes the Linux default unless the operator supplies an authoritative declaration.
        - Otherwise return nulls so normal triage can continue.

        Evidence requirements:
        - duplicate: evidence_urls must include the matching candidate Job/issue URL.
        - already_implemented: evidence_urls must include the merged PR URL, and reason must be one sentence summarizing why that PR covers the issue.

        Return ONLY compact JSON with this exact shape:
        {"epic_id":null,"invalid":{"kind":null,"reason":"","evidence_urls":[]},"placement_recommendation":null}

        A recommendation has this exact shape:
        {"profile":"macos_desktop","explanation":"One concise sentence grounded in the requested work.","confidence":0.8}

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
