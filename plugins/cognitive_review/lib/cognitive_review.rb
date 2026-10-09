module CognitiveReview
  extend Syrus::PluginApi

  syrus_plugin "cognitive_review" do
    experimental true
    display_name "Review Notes"
    description "Agent-authored review notes for changed diff ranges, surfaced in the Job review tab."
    long_description "Review Notes runs a best-effort agentic pass after implementation workflows and asks the agent to flag changed diff ranges that deserve operator attention. Notes are submitted through a plugin-owned workflow MCP tool and projected back into the review tab through plugin-owned diff annotations.\n\nThe Job review tab includes a PR-level review-note debt rollup: total flagged ranges, open/unacknowledged notes, acknowledged notes, discussed, user-commented, dismissed, and zero-note states. Acknowledged, discussed, or user-commented covered ranges count as acknowledged; dismissed notes are reported separately, and unflagged changed lines do not create PR-level review-note debt.\n\nDisabling the plugin withholds the review-note workflow provider, MCP tool set, API routes, and review-tab annotations without deleting note records or workflow artifacts already written. Agent Memory is optional: when available the review pass can use its normal memory context, and when it is not available the prompt falls back to Job, repository, and diff context."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/cognitive_review.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled false
    disableable true
    optionally_depends_on [ "agent_memory" ]

    provides post_implementation_review_provider: "CognitiveReview::PostImplementationReviewProvider",
             diff_review_annotation_provider: "CognitiveReview::DiffReviewAnnotationProvider",
             mcp_tool_set: "CognitiveReview::McpToolSet"

    route :get, "/api/v1/app/jobs/:job_id/review_notes", to: "api/v1/app/cognitive_review_notes#index"
    route :get, "/api/v1/app/jobs/:job_id/review_notes/:id", to: "api/v1/app/cognitive_review_notes#show"
    route :post, "/api/v1/app/jobs/:job_id/review_notes/:id/acknowledge", to: "api/v1/app/cognitive_review_notes#acknowledge"
    route :post, "/api/v1/app/jobs/:job_id/review_notes/:id/start_discussion", to: "api/v1/app/cognitive_review_notes#start_discussion"
    route :post, "/api/v1/app/jobs/:job_id/review_notes/:id/discussion_entries", to: "api/v1/app/cognitive_review_notes#create_discussion_entry"

    route :get, "/api/v1/app/jobs/:job_id/cognitive_review_notes", to: "api/v1/app/cognitive_review_notes#index"
    route :get, "/api/v1/app/jobs/:job_id/cognitive_review_notes/:id", to: "api/v1/app/cognitive_review_notes#show"
    route :post, "/api/v1/app/jobs/:job_id/cognitive_review_notes/:id/acknowledge", to: "api/v1/app/cognitive_review_notes#acknowledge"
    route :post, "/api/v1/app/jobs/:job_id/cognitive_review_notes/:id/start_discussion", to: "api/v1/app/cognitive_review_notes#start_discussion"
    route :post, "/api/v1/app/jobs/:job_id/cognitive_review_notes/:id/discussion_entries", to: "api/v1/app/cognitive_review_notes#create_discussion_entry"
  end
end
