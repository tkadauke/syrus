module ReviewPlanning
  extend Syrus::PluginApi

  syrus_plugin "review_planning" do
    display_name "Review plan"
    description "Compatibility owner for the retired review_plan workflow step and the legacy `review_plan:` .syrus.yml key."
    long_description "Review planning used to post a plan comment on the pull request after `pr_open`. That behavior was retired and no new workflow materializes the step. This plugin owns what is left of it: the `review_plan` step kind, so workflows persisted before the retirement still execute (they record a skip and advance), and the legacy boolean `review_plan:` key in `.syrus.yml`, which is parsed and ignored so older repositories stay valid.\n\nDisabling the plugin is refused while a non-terminal workflow still holds a `review_plan` step; otherwise it is a clean no-op. Recorded steps and artifacts are never touched."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled true
    # Disableable: the step is retired and advisory (`fail_policy: advance`), no
    # new workflow contains it, and nothing downstream reads it. The standard
    # plugin guard refuses a disable while a non-terminal workflow still holds
    # one, which is the only case where the handler is still needed. Existing
    # step rows and artifacts stay in place either way.
    disableable true
    provides workflow_kinds: "ReviewPlanning::WorkflowKinds",
             repository_configuration: "ReviewPlanning::RepositoryConfiguration"
  end
end
