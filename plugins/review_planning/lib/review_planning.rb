module ReviewPlanning
  extend Syrus::Host::PluginApi

  syrus_plugin "review_planning" do
    experimental false
    requires_syrus nil
    display_name "Review plan"
    description "Optional self-review pass after a pull request opens: the implementing agent comments on the spots in its own diff most worth a human reviewer's attention."
    long_description "After the pull request is opened, the agent that implemented the change looks back over its own diff and posts one comment pointing reviewers at specific file and line locations worth a closer look, with a short note on why. A repository opts in with `review_plan: true` in `.syrus.yml`; if nothing stands out, no comment is posted.

The step runs once after `pr_open` through the `workflow:post_pr` anchor and is best-effort: it never fails the workflow. Disabling the plugin removes the step from new workflows without an error and the `review_plan:` key is ignored; recorded review-plan artifacts are left in place."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/review_planning.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled true
    # Disableable: the self-review is advisory (`fail_policy: advance`) and
    # nothing downstream consumes it, so omitting it from new workflows is a
    # clean no-op. The standard plugin guard refuses a disable while a
    # non-terminal workflow still holds a review_plan step. Recorded artifacts
    # stay in place.
    disableable true
    workflow_kinds(
      step_kinds: [
        {
          kind: "review_plan", handler: "ReviewPlanning::Step",
          label: "Review plan", style: "bg-orange-100 text-orange-700", agentic: true,
          agent_role: "workflow:summary_test_plan",
          required_mcp_tools: %w[submit_review_plan],
          fail_policy: :advance,
          resource_profile_fallback_step_kinds: %w[implement],
          skip_if_artifact: "review_plan"
        }
      ]
    )
    provides "workflow:post_pr" => "ReviewPlanning::WorkflowPostPr",
             mcp_tool_set: "ReviewPlanning::McpToolSet",
             permission_provider: "ReviewPlanning::PermissionProvider"
    repository_configuration key: "review_planning.config", schema_version: 1, legacy_keys: [ "review_plan" ],
                             provider: "ReviewPlanning::RepositoryConfiguration"
  end
end
