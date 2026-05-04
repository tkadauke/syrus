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
      prompt: <<~PROMPT.strip
        Analyze this project's package manager files and create or update .syrus.yml
        in the project root with the appropriate prepare commands.

        Check for: Gemfile (bundle install), package.json (npm ci or yarn install),
        requirements.txt (pip install -r requirements.txt), go.mod (go mod download),
        Cargo.toml (cargo fetch), pyproject.toml (poetry install or pip install -e .).

        The prepare section lists shell commands Syrus runs before invoking the agent
        each time — typically dependency installation. Keep commands minimal and
        idempotent. Example:

        ```yaml
        prepare:
          - bundle install
          - npm ci
        ```

        If .syrus.yml already exists, update only the prepare section and preserve
        any other settings. If it doesn't exist, create it with just the prepare section.
      PROMPT
    ),
    new(
      id: "add-github-actions-ci",
      name: "Add GitHub Actions CI",
      description: "Add a CI workflow that runs tests on every push and pull request.",
      prompt: <<~PROMPT.strip
        Add a GitHub Actions CI workflow to this project. The workflow should:
        - Trigger on push to the default branch and on pull requests
        - Install dependencies appropriate for this project type
        - Run the test suite
        - Fail fast when tests fail

        Detect the project type (Ruby/Rails, Node.js, Python, Go, Rust, etc.) and
        write an appropriate .github/workflows/ci.yml. Use the standard actions for
        the language ecosystem (actions/checkout, actions/setup-ruby, etc.) and
        pin action versions with their SHA hashes for supply-chain safety.

        If a CI workflow already exists, improve it rather than replace it — add
        missing matrix entries, fix outdated action versions, or add a missing test step.
      PROMPT
    ),
    new(
      id: "update-dependencies",
      name: "Update dependencies",
      description: "Update all packages to their latest compatible versions and fix any issues.",
      prompt: <<~PROMPT.strip
        Update this project's dependencies to their latest compatible versions.

        For each package manager present (Gemfile, package.json, requirements.txt, etc.):
        1. Update packages to the latest versions that satisfy existing version constraints
        2. Run the test suite to catch any regressions
        3. Fix any compatibility issues that arise
        4. Commit the updated lockfile(s)

        Be conservative: prefer updating within existing constraints first. Only widen
        a constraint when a dependency has a known security vulnerability or the current
        constraint is unreasonably tight. Note which packages were updated and why in
        the commit message.
      PROMPT
    ),
  ].freeze

  def self.all
    TEMPLATES
  end

  def self.find(id)
    TEMPLATES.find { |t| t.id == id }
  end
end
