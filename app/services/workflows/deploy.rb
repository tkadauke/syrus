module Workflows
  # Runs the repository's configured `.syrus.yml` `deploy.run` command
  # against this Job's workspace — launched directly on a Job (manual
  # deploy) or by the continuous-deploy auto-trigger, both outside this
  # Job's scope. Modeled as a real Workflow rather than a bespoke
  # side-model so it gets retry-from-failed-step, Run transcripts, the
  # admin repair toolkit, and WorkflowWorkspacePruneJob cleanup for free.
  #
  #   prepare → deploy
  #
  # `prepare` is the same deterministic setup step every other chain
  # uses. `deploy` is entirely non-agentic — there is no LLM turn in
  # this chain at all.
  class Deploy < Base
    steps :prepare, :deploy

    def self.trigger_kind = "deploy"

    def self.agentic? = false
  end
end
