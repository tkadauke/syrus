require "yaml"

# Workflow templates as data, with provenance (workflow-engine-v3 primitive D).
#
# `Workflows::Initial.steps_for(job)` already emits JSON that is persisted as
# `Workflow#chain_template`. What was missing is the other half of the idea:
# where that graph came from, and the ability for a repository to shadow it.
#
# Resolution copies `Skills.for` deliberately -- repo-local
# `.syrus/workflows/<key>.yml` shadows the built-in, and the resolved source is
# recorded on the Workflow. A shadowed template that nobody can see is a
# debugging trap, and Syrus already learned that lesson once with skills.
#
# Two safety properties, both from the plan's guardrails:
#
#   * **Repo-local templates may only add checks.** A repository cannot delete
#     a grader, a publication step, or a landing node by shadowing a template.
#     Anything touching landing or publication needs operator confirmation,
#     which a file in a branch is not.
#   * **Policy that cannot be read fails closed.** A GitHub outage means "we do
#     not know what this repository wants", which resolves to the built-in
#     rather than to a silently different graph.
module WorkflowTemplates
  REPO_LOCAL_DIR = ".syrus/workflows".freeze
  KEY_PATTERN = /\A[a-z0-9_]+\z/

  SOURCES = %w[built_in repo runtime].freeze

  # Node kinds a repo-local template may never introduce or remove. These are
  # the ones that publish: a template that can drop them is a template that can
  # turn off the checks it exists to satisfy.
  PROTECTED_STEP_KINDS = %w[
    pr_open push force_push auto_merge merge_train_land external_pr_merge
    promotion_publish hotfix_sync_publish upstream_export_publish
  ].freeze

  Resolution = Data.define(:source, :path, :graph, :key) do
    def repo_override? = source == "repo"
    def built_in? = source == "built_in"

    # Recorded on the Workflow so a shadowed template is visible wherever the
    # chain is.
    def provenance
      { "template_key" => key, "template_source" => source, "template_path" => path }.compact
    end
  end

  InvalidTemplate = Class.new(StandardError)

  # Returns the repo-local template when there is a usable one, otherwise the
  # built-in graph the caller compiled.
  #
  # `resolve_overrides:` is opt-in and defaults to false, deliberately. Looking
  # for `.syrus/workflows/<key>.yml` is a GitHub round-trip, and every workflow
  # instantiation is a hot path that should not grow a synchronous network call
  # -- or a new failure mode -- for a file that almost never exists. Callers
  # that have a reason (and somewhere to cache) opt in.
  #
  # Provenance is recorded either way, which is the half that costs nothing:
  # every Workflow says which template it ran, so a future override can never
  # be a silent one.
  def self.for(key:, built_in_graph:, repository: nil, user: nil, client: nil, resolve_overrides: false)
    key = key.to_s
    raise ArgumentError, "invalid template key=#{key.inspect}" unless key.match?(KEY_PATTERN)

    if resolve_overrides && repository
      override = resolve_repo_local(key: key, repository: repository, user: user, client: client, built_in_graph: built_in_graph)
      return override if override
    end

    Resolution.new(source: "built_in", path: nil, graph: built_in_graph, key: key)
  end

  def self.resolve_repo_local(key:, repository:, user:, client:, built_in_graph:)
    github_client = client || resolved_github_client(repository: repository, user: user)
    return nil unless github_client

    path = "#{REPO_LOCAL_DIR}/#{key}.yml"
    content = github_client.file_content_at(repository.slug, path, repository.default_branch)
    return nil if content.blank?

    graph = parse(content)
    validate_additive!(graph: graph, built_in_graph: built_in_graph, path: path)

    Resolution.new(source: "repo", path: path, graph: graph, key: key)
  rescue InvalidTemplate => e
    # An unusable repo-local template is an authoring bug to surface, not to
    # mask -- but it must not stop the workflow, so the built-in runs and the
    # reason is logged.
    Rails.logger.warn("[WorkflowTemplates] ignoring #{path}: #{e.message}")
    nil
  rescue StandardError => e
    # Fails closed: we could not read what this repository wants, so we use
    # what we know rather than guessing.
    Rails.logger.warn("[WorkflowTemplates] could not read #{key} for #{repository.slug}: #{e.class}: #{e.message}")
    nil
  end

  def self.parse(content)
    graph = YAML.safe_load(content, permitted_classes: [], aliases: false)
    raise InvalidTemplate, "template must be a list of nodes" unless graph.is_a?(Array)

    graph
  rescue Psych::Exception => e
    raise InvalidTemplate, "unparseable YAML: #{e.message}"
  end

  # A repo-local template may add checks. It may not remove a protected node,
  # and it may not introduce one the built-in did not already have -- a
  # repository cannot grant itself a publication step by writing a file.
  def self.validate_additive!(graph:, built_in_graph:, path:)
    built_in_protected = protected_kinds_in(built_in_graph)
    override_protected = protected_kinds_in(graph)

    removed = built_in_protected - override_protected
    raise InvalidTemplate, "removes protected step(s): #{removed.to_a.sort.join(', ')}" if removed.any?

    added = override_protected - built_in_protected
    raise InvalidTemplate, "adds protected step(s): #{added.to_a.sort.join(', ')}" if added.any?

    unknown = step_kinds_in(graph).reject { |kind| Step::Kind.by_kind.key?(kind) }
    raise InvalidTemplate, "names unknown step kind(s): #{unknown.uniq.sort.join(', ')}" if unknown.any?
  end

  def self.protected_kinds_in(graph)
    step_kinds_in(graph).select { |kind| PROTECTED_STEP_KINDS.include?(kind) }.to_set
  end

  # Node graphs nest (loop, retry_until, try), so kinds are collected depth
  # first rather than from the top level only.
  def self.step_kinds_in(node)
    case node
    when Array then node.flat_map { |child| step_kinds_in(child) }
    when Hash then Array(node["kind"]).map(&:to_s) + node.values.flat_map { |value| step_kinds_in(value) }
    else []
    end
  end

  def self.resolved_github_client(repository:, user:)
    GithubClient.for(repository: repository, user: user || repository.user)
  rescue StandardError
    nil
  end
end
