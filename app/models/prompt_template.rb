class PromptTemplate
  attr_reader :id, :name, :description

  def initialize(id:, name:, description:)
    @id          = id
    @name        = name
    @description = description
  end

  TEMPLATES = [
    new(
      id: "configure-syrus-prep",
      name: "Configure Syrus build dependencies",
      description: "Detect package managers and write .syrus.yml so Syrus installs dependencies before each run."
    ),
    new(
      id: "add-github-actions-ci",
      name: "Add GitHub Actions CI",
      description: "Add a CI workflow that runs tests on every push and pull request."
    ),
    new(
      id: "update-dependencies",
      name: "Update dependencies",
      description: "Update all packages to their latest compatible versions and fix any issues."
    ),
    new(
      id: "configure-preview-seed-data",
      name: "Seed preview demo data",
      description: "One-time onboarding: make the repo's seed mechanism idempotent and add demo user + sample data so previews reach a populated, authenticated state."
    )
  ].freeze

  # Returns the skill's instruction body (frontmatter stripped) so the agent
  # receives the full task instructions rather than a bare slash command that
  # only works in interactive Claude Code sessions.
  def prompt
    skill_file = Rails.root.join("lib/agent_skills/#{id}.md")
    return "/#{id}" unless skill_file.exist?

    skill_file.read.sub(/\A---\n.*?\n---\n/m, "").strip
  end

  def self.all
    TEMPLATES
  end

  def self.find(id)
    TEMPLATES.find { |t| t.id == id }
  end
end
