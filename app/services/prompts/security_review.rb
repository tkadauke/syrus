module Prompts
  class SecurityReview < AdversarialReview
    private

    def step_orientation = "You are running the security_review step for Syrus."

    def independence
      <<~TEXT.strip
        Approach this code as an independent security reviewer with no knowledge of how the implementing agent reasoned.
        Inspect the workspace and diff for exploitable weaknesses and unsafe trust-boundary assumptions. Pay particular attention to authentication and authorization, injection, secret and credential handling, SSRF, path traversal, unsafe deserialization, dependency and supply-chain changes, sensitive-data logging, cryptography, and denial-of-service risks.
        Require concrete evidence and distinguish exploitable issues from defense-in-depth suggestions.
        Do not make code changes; any edits you make are ephemeral and will not be committed.
        Do not start expensive builds or broad test suites; deterministic verification belongs to Syrus grader steps.
      TEXT
    end

    def prior_review_context
      return "Prior security review findings: none." if @prior_findings.empty?

      [ "Prior security review findings:", @prior_findings.map { |finding| render_finding(finding) }.join("\n\n") ].join("\n\n")
    end

    def submission_instructions
      <<~TEXT.strip
        When finished, call the `submit_security_review` MCP tool exposed by `syrus-mcp-sidecar` with both required fields:
        - critique: concise Markdown describing concrete security findings, or a short note that no blocking issues were found.
        - verdict: "needs_work" when implementation changes are needed, otherwise "approved".

        Example: {"verdict":"approved","critique":"No blocking security issues found."}
        Do not call a generic findings tool; this step is only complete once `submit_security_review` has been called.
      TEXT
    end
  end
end
