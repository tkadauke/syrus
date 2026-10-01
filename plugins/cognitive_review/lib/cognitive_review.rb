module CognitiveReview
  extend Syrus::PluginApi

  syrus_plugin "cognitive_review" do
    display_name "Cognitive Review"
    description "Agent-authored review notes for changed diff ranges, surfaced in the Job review tab."
    long_description "Cognitive Review runs a best-effort agentic pass after implementation workflows and asks the agent to flag changed diff ranges that deserve operator attention. Notes are submitted through a plugin-owned workflow MCP tool and projected back into the review tab through plugin-owned diff annotations.\n\nDisabling the plugin withholds the review-note workflow provider, MCP tool set, and review-tab annotations without deleting note artifacts already written to workflows. Agent Memory is optional: when available the review pass can use its normal memory context, and when it is not available the prompt falls back to Job, repository, and diff context."
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
  end
end
