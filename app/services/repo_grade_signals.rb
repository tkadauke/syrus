require "pathname"

# Deterministic detector for `grade:` step *candidates* — signals in a
# repository's own tooling (test runners, lint/typecheck config) plus
# any CI workflow files already present. Distinct from RepoGradePlan,
# which parses graders already *configured* in `.syrus.yml`; this class
# proposes new ones for a repo that doesn't have them configured yet.
#
# The `onboard-to-syrus` built-in skill (Skills::OnboardToSyrus) embeds
# RULE_DESCRIPTIONS into its agent instructions so the agent's own repo
# scan can't drift from a single source of truth — the same way it
# reuses the combined `signals` of registered :prepare_detector plugins for
# the `prepare:` section instead of hand-describing lockfile detection a
# second time.
#
# Pure; no side effects. Candidates are suggestions surfaced to the
# onboarding agent, not commands Syrus runs automatically.
class RepoGradeSignals
  DEFAULT_REQUIRED = true
  DEFAULT_TIMEOUT_MINUTES = 15
  CI_WORKFLOW_GLOB = ".github/workflows/*.y*ml".freeze

  # `evidence` is the human-readable signal that matched (a file/dir
  # name, or a config section header) — surfaced so a report or gap
  # analysis can cite why a candidate was suggested.
  Candidate = Data.define(:name, :run, :required, :timeout_minutes, :evidence)
  Result = Data.define(:candidates, :ci_workflow_paths, :ci_run_commands)

  # Static rule metadata (name/run/human-readable signal description),
  # independent of any workspace — Skills::OnboardToSyrus renders this
  # into its instructions without needing a live repo to scan.
  RuleDescription = Data.define(:name, :run, :signals)

  RULE_DESCRIPTIONS = [
    RuleDescription.new(name: "rspec", run: "bin/rspec", signals: "a spec/ directory or .rspec file"),
    RuleDescription.new(name: "jest", run: "npx jest", signals: "a jest.config.* file"),
    RuleDescription.new(name: "pytest", run: "pytest", signals: "pytest.ini, a [tool.pytest.ini_options] section in pyproject.toml, or a [tool:pytest] section in setup.cfg"),
    RuleDescription.new(name: "go-test", run: "go test ./...", signals: "a go.mod file with *_test.go files present"),
    RuleDescription.new(name: "rubocop", run: "bundle exec rubocop", signals: "a .rubocop.yml file"),
    RuleDescription.new(name: "eslint", run: "npx eslint .", signals: "an .eslintrc* or eslint.config.* file"),
    RuleDescription.new(name: "typecheck", run: "npx tsc --noEmit", signals: "a tsconfig.json file")
  ].freeze

  def self.for(workspace_path)
    new(workspace_path).resolve
  end

  def initialize(workspace_path)
    @path = Pathname.new(workspace_path)
  end

  def resolve
    Result.new(
      candidates: detected_candidates,
      ci_workflow_paths: detected_ci_workflow_paths,
      ci_run_commands: detected_ci_run_commands
    )
  end

  private

  def detected_candidates
    [
      candidate("rspec", "bin/rspec", rspec_evidence),
      candidate("jest", "npx jest", jest_evidence),
      candidate("pytest", "pytest", pytest_evidence),
      candidate("go-test", "go test ./...", go_test_evidence),
      candidate("rubocop", "bundle exec rubocop", rubocop_evidence),
      candidate("eslint", "npx eslint .", eslint_evidence),
      candidate("typecheck", "npx tsc --noEmit", typecheck_evidence)
    ].compact
  end

  def candidate(name, run, evidence)
    return nil unless evidence

    Candidate.new(name: name, run: run, required: DEFAULT_REQUIRED,
                  timeout_minutes: DEFAULT_TIMEOUT_MINUTES, evidence: evidence)
  end

  def rspec_evidence
    return "spec/" if @path.join("spec").directory?
    ".rspec" if @path.join(".rspec").exist?
  end

  def jest_evidence
    %w[jest.config.js jest.config.ts jest.config.cjs jest.config.mjs jest.config.json]
      .find { |f| @path.join(f).exist? }
  end

  def pytest_evidence
    return "pytest.ini" if @path.join("pytest.ini").exist?
    return "pyproject.toml [tool.pytest.ini_options]" if file_contains?("pyproject.toml", "[tool.pytest.ini_options]")
    "setup.cfg [tool:pytest]" if file_contains?("setup.cfg", "[tool:pytest]")
  end

  def go_test_evidence
    return unless @path.join("go.mod").exist?

    "go.mod" if Dir.glob(@path.join("**/*_test.go").to_s).any?
  end

  def rubocop_evidence
    ".rubocop.yml" if @path.join(".rubocop.yml").exist?
  end

  def eslint_evidence
    %w[.eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml
       eslint.config.js eslint.config.mjs eslint.config.cjs]
      .find { |f| @path.join(f).exist? }
  end

  def typecheck_evidence
    "tsconfig.json" if @path.join("tsconfig.json").exist?
  end

  def file_contains?(rel_path, substring)
    file = @path.join(rel_path)
    file.file? && file.read.include?(substring)
  rescue Errno::ENOENT, Errno::EISDIR
    false
  end

  def detected_ci_workflow_paths
    Dir.glob(@path.join(CI_WORKFLOW_GLOB).to_s).sort.map { |p| Pathname.new(p).relative_path_from(@path).to_s }
  end

  # Best-effort extraction of `run:` step commands already used by the
  # repo's own CI — the strongest signal for "this is the command that
  # actually validates this repo." Deliberately shallow (no matrix/
  # composite-action resolution): a flat, deduplicated list of literal
  # `run:` strings across every job/step, skipped entirely on parse
  # failure rather than raising.
  def detected_ci_run_commands
    detected_ci_workflow_paths.flat_map { |rel| ci_run_commands_in(@path.join(rel)) }.uniq
  end

  def ci_run_commands_in(file)
    workflow = YAML.safe_load(file.read, aliases: true)
    return [] unless workflow.is_a?(Hash)

    Array(workflow["jobs"]).flat_map do |_job_name, job|
      next [] unless job.is_a?(Hash)

      Array(job["steps"]).filter_map do |step|
        next unless step.is_a?(Hash)

        step["run"]&.to_s&.strip.presence
      end
    end
  rescue Psych::SyntaxError, Errno::ENOENT
    []
  end
end
