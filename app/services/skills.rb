# Skills are named, freeform instruction sets (SKILL.md-style markdown +
# a declared parameter schema) — the escape hatch for tasks that resist
# decomposition into the deterministic Workflow/Step pipeline. See
# EPIC-233 for the full feature; this Job only establishes the on-disk
# format and resolution logic that later Jobs (Job/Workflow/chat
# integration) build on.
#
# Two tiers, resolved in order:
#   1. repo-local  — `.syrus/skills/<name>/SKILL.md`, git-tracked in the
#      target repository like `.syrus.yml`. Authored via a Syrus chat in
#      Coding Mode.
#   2. built-in    — Ruby PORO classes under app/services/skills/,
#      registered in Skills::Registry (Step::Kind / Workflow::TriggerKind
#      style: a single array-backed registry, not scattered constants).
#
# A repo-local skill shadows a built-in of the same name — no separate
# namespace. `Skills.for` always reports which tier actually resolved
# (`:repo_override` or `:built_in`) so a shadowed skill is never a
# silent debugging trap; later Jobs persist that onto Run/Workflow
# artifacts.
#
# Distinct from the contributor-facing `.claude/skills/*/SKILL.md` files
# already in this repo (see lib/agent_skills/, AgentSkillsSyncer) — those
# drive Claude Code's own skill system and are being cleaned up in
# JOB-3144/JOB-3145. Do not conflate the two or reuse that directory.
module Skills
  REPO_LOCAL_DIR = ".syrus/skills".freeze
  NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/

  NotFoundError = Class.new(StandardError)

  # source: :repo_override or :built_in
  # path:   repo-relative SKILL.md path, set only for :repo_override
  # klass:  the Skills:: PORO class, set only for :built_in
  # definition: uniform Skills::Definition regardless of source
  Resolution = Data.define(:source, :path, :klass, :definition)

  # Mirrors the fallback shape of GithubClient.for (installation, then
  # user PAT): try the repo-local override first, fall back to the
  # built-in registry. Raises Skills::NotFoundError if neither tier has
  # a skill by this name. A repo-local SKILL.md that exists but fails to
  # parse raises Skills::SkillMarkdown::ParseError rather than silently
  # falling back to a built-in of the same name — a broken repo-local
  # skill is an authoring bug to surface, not to mask.
  def self.for(repository:, name:, user: nil, client: nil)
    raise ArgumentError, "repository is required" if repository.nil?

    name = name.to_s.strip
    raise ArgumentError, "name is required" if name.empty?
    raise ArgumentError, "invalid skill name=#{name.inspect}" unless name.match?(NAME_PATTERN)

    resolve_repo_local(repository: repository, user: user, client: client, name: name) ||
      resolve_built_in(name: name)
  end

  def self.resolve_repo_local(repository:, user:, client:, name:)
    return nil unless credentials_available?(repository: repository, user: user)

    github_client = client || resolved_github_client(repository: repository, user: user)
    return nil unless github_client

    path = "#{REPO_LOCAL_DIR}/#{name}/SKILL.md"
    file = github_client.file_content_at(repository.slug, path, repository.default_branch)
    return nil unless file

    definition = SkillMarkdown.parse(file.fetch(:content), name: name)
    Resolution.new(source: :repo_override, path: path, klass: nil, definition: definition)
  end
  private_class_method :resolve_repo_local

  # `GithubClient.for` can fall back to auth sources that don't return a
  # usable GithubClient; guard here the same way RepoCoveragePlanReader
  # does. Only applies when we actually called GithubClient.for — an
  # injected test `client:` is used as-is.
  def self.resolved_github_client(repository:, user:)
    client = GithubClient.for(repository: repository, user: user || repository.user)
    client if client.is_a?(GithubClient)
  end
  private_class_method :resolved_github_client

  def self.resolve_built_in(name:)
    klass = Registry.class_for(name)
    Resolution.new(source: :built_in, path: nil, klass: klass, definition: klass.definition)
  end
  private_class_method :resolve_built_in

  def self.credentials_available?(repository:, user:)
    repository.installation&.active? || (user || repository.user)&.github_token.present?
  end
  private_class_method :credentials_available?
end
