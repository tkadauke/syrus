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
  # `workspace_path` is forwarded to a built-in skill's own `.definition`
  # (see Skills::Base) so it can tailor its instructions to a real
  # on-disk checkout — currently only Steps::RunSkill passes one, once
  # the Workflow's shared workspace is set up. Every other caller
  # (picker, chat slash command, ScheduledTask fire) omits it and gets
  # each skill's generic, repo-agnostic instructions.
  def self.for(repository:, name:, user: nil, client: nil, workspace_path: nil)
    raise ArgumentError, "repository is required" if repository.nil?

    name = name.to_s.strip
    raise ArgumentError, "name is required" if name.empty?
    raise ArgumentError, "invalid skill name=#{name.inspect}" unless name.match?(NAME_PATTERN)

    resolve_repo_local(repository: repository, user: user, client: client, name: name) ||
      resolve_built_in(name: name, workspace_path: workspace_path)
  end

  # Lists every skill available to `repository` — the built-in registry
  # plus any repo-local `.syrus/skills/<name>/SKILL.md` files — each
  # resolved to the same Resolution shape `.for` returns, so a caller
  # (the skill picker API) gets uniform source/path/definition data and
  # can tell a repo-local skill apart from a built-in one it shadows.
  # A repo-local SKILL.md that fails to parse is logged and omitted
  # rather than blowing up the whole listing (unlike `.for`, which
  # raises for a single explicit lookup) — one broken skill shouldn't
  # make every other skill unlaunchable from the picker.
  def self.all_for(repository:, user: nil, client: nil)
    raise ArgumentError, "repository is required" if repository.nil?

    repo_local_names = repo_local_skill_names(repository: repository, user: user, client: client)

    (Registry.values + repo_local_names).uniq.sort.filter_map do |name|
      resolve_for_listing(
        repository: repository, user: user, client: client, name: name,
        known_repo_local: repo_local_names.include?(name)
      )
    end
  end

  def self.repo_local_skill_names(repository:, user:, client:)
    return [] unless credentials_available?(repository: repository, user: user)

    github_client = client || resolved_github_client(repository: repository, user: user)
    return [] unless github_client

    tree = github_client.file_tree_at(repository.slug, repository.default_branch)
    Array(tree[:items])
      .filter_map { |item| item[:path][%r{\A#{Regexp.escape(REPO_LOCAL_DIR)}/([^/]+)/SKILL\.md\z}, 1] }
      .select { |name| name.match?(NAME_PATTERN) }
  rescue Octokit::Error => e
    Rails.logger.warn("[Skills.all_for] failed to list repo-local skills for #{repository.slug}: #{e.class}: #{e.message}")
    []
  end
  private_class_method :repo_local_skill_names

  # Skips the repo-local file_content_at round-trip entirely for a name
  # the tree walk (repo_local_skill_names) already proved has no
  # override — avoids one GitHub API call per built-in skill on every
  # listing as the built-in registry grows.
  def self.resolve_for_listing(repository:, user:, client:, name:, known_repo_local:)
    return resolve_built_in(name: name) unless known_repo_local

    resolve_repo_local(repository: repository, user: user, client: client, name: name) ||
      resolve_built_in(name: name)
  rescue Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
    Rails.logger.warn("[Skills.all_for] skill=#{name.inspect} failed to parse for #{repository.slug}: #{e.class}: #{e.message}")
    nil
  end
  private_class_method :resolve_for_listing

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

  def self.resolve_built_in(name:, workspace_path: nil)
    klass = Registry.class_for(name)
    Resolution.new(source: :built_in, path: nil, klass: klass, definition: klass.definition(workspace_path: workspace_path))
  end
  private_class_method :resolve_built_in

  def self.credentials_available?(repository:, user:)
    repository.installation&.active? || (user || repository.user)&.github_token.present?
  end
  private_class_method :credentials_available?
end
