class PromptTemplate
  attr_reader :id, :name, :description, :prompt

  def initialize(id:, name:, description:, prompt:)
    @id          = id
    @name        = name
    @description = description
    @prompt      = prompt
  end

  TEMPLATES = [
    new(
      id: "configure-syrus-prep",
      name: "Configure Syrus build dependencies",
      description: "Detect package managers and write .syrus.yml so Syrus installs dependencies before each run.",
      prompt: "/configure-syrus-prep"
    ),
    new(
      id: "add-github-actions-ci",
      name: "Add GitHub Actions CI",
      description: "Add a CI workflow that runs tests on every push and pull request.",
      prompt: "/add-github-actions-ci"
    ),
    new(
      id: "update-dependencies",
      name: "Update dependencies",
      description: "Update all packages to their latest compatible versions and fix any issues.",
      prompt: "/update-dependencies"
    ),
  ].freeze

  def self.all
    TEMPLATES
  end

  def self.find(id)
    TEMPLATES.find { |t| t.id == id }
  end
end
