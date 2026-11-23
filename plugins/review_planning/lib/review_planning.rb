module ReviewPlanning
  extend Syrus::PluginApi

  syrus_plugin "review_planning" do
    display_name "Review plan"
    description "Optional self-review pass after a pull request opens: the implementing agent comments on the spots in its own diff most worth a human reviewer's attention."
    long_description "After the pull request is opened, the agent that implemented the change looks back over its own diff and posts one comment pointing reviewers at specific file and line locations worth a closer look, with a short note on why. A repository opts in with `review_plan: true` in `.syrus.yml`; if nothing stands out, no comment is posted.

The step runs once after `pr_open` through the `workflow:post_pr` anchor and is best-effort: it never fails the workflow. Disabling the plugin removes the step from new workflows without an error and the `review_plan:` key is ignored; recorded review-plan artifacts are left in place."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled true
    # Disableable: the self-review is advisory (`fail_policy: advance`) and
    # nothing downstream consumes it, so omitting it from new workflows is a
    # clean no-op. The standard plugin guard refuses a disable while a
    # non-terminal workflow still holds a review_plan step. Recorded artifacts
    # stay in place.
    disableable true
    provides workflow_kinds: "ReviewPlanning::WorkflowKinds",
             "workflow:post_pr" => "ReviewPlanning::WorkflowPostPr",
             repository_configuration: "ReviewPlanning::RepositoryConfiguration",
             mcp_tool_set: "ReviewPlanning::McpToolSet",
             permission_provider: "ReviewPlanning::PermissionProvider"
  end
end
