# Generalizes "what a :step_environment plugin provider's #extra_env hook
# is computing values for" beyond Workflow. Steps::Prepare and Steps::Grader
# always run inside a Workflow, but ChatWorkspacePrepareJob prepares a
# Coding Mode chat workspace, which has a ChatSession + Repository and no
# Workflow at all. A provider like BuildCache::StepEnvironment needs a
# stable id (to derive a per-scope daemon port, say) and a repository (to
# read repository-level settings) from whichever caller it's serving,
# without knowing or caring which kind of caller that is.
#
# `namespace` keeps two different scope kinds' ids from colliding when a
# provider derives something purely from the id -- a Workflow and a
# ChatSession that happen to share the same numeric id must resolve to
# different derived values. See #cache_key.
class PrepareScope
  attr_reader :namespace, :id, :repository

  def initialize(namespace:, id:, repository:)
    @namespace = namespace.to_s
    @id = id
    @repository = repository
  end

  def self.for_workflow(workflow)
    new(namespace: "workflow", id: workflow.id, repository: workflow.job&.repository)
  end

  def self.for_chat_session(chat_session, repository:)
    new(namespace: "chat", id: chat_session.id, repository: repository)
  end

  # Stable string a provider can hash to derive a scope-specific value (a
  # TCP port, say) -- namespaced so a Workflow id and a ChatSession id with
  # the same numeric value never collide.
  def cache_key
    "#{namespace}:#{id}"
  end
end
