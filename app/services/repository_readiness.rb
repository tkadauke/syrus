require "tmpdir"

class RepositoryReadiness
  Result = Data.define(:status, :summary, :revision, :repository_size_bytes, :file_count, :checks, :prepare_commands, :grader_commands, :required_capabilities)

  MATERIALIZED_PATHS = %w[
    .syrus.yml Gemfile Gemfile.lock package.json package-lock.json yarn.lock pnpm-lock.yaml
    pyproject.toml poetry.lock uv.lock requirements.txt go.mod go.sum Cargo.toml Cargo.lock
    .ruby-version .node-version .python-version .tool-versions mise.toml
    pytest.ini setup.cfg tsconfig.json .rubocop.yml
    Dockerfile docker-compose.yml compose.yml .env.example
  ].freeze
  SYSTEM_HINTS = {
    /\b(?:apt-get|apt install)\b/ => "Repository configuration references apt packages.",
    /\b(?:brew install)\b/ => "Repository configuration references Homebrew packages.",
    /\b(?:docker|docker compose|docker-compose)\b/i => "Repository configuration references Docker.",
    /\b(?:postgres|mysql|redis|elasticsearch|minio)\b/i => "Repository configuration references an external service."
  }.freeze

  def self.call(repository:, user: nil)
    new(repository:, user:).call
  end

  def initialize(repository:, user: nil)
    @repository = repository
    @user = user || repository.user
    @content = RepositoryContent.for(repository, user: @user)
  end

  def call
    revision = @content.resolve(@repository.default_branch)
    entries, truncated = repository_tree(revision)
    checks = []
    checks << check("access", "pass", "Default branch #{@repository.default_branch} is readable at #{revision.id.to_s.first(12)}.")
    checks << credential_check
    checks << check("size", truncated ? "warning" : "pass", size_message(entries, truncated))

    Dir.mktmpdir("syrus-readiness-") do |dir|
      materialize(dir, revision, entries)
      prep = RepoPrepPlan.for(dir)
      grade = RepoGradePlan.for(dir)
      grade_signals = RepoGradeSignals.for(dir)
      config = parse_config(dir, checks)
      checks.concat(heuristic_checks(dir, entries, prep, grade, grade_signals))
      capabilities = required_capabilities(config)
      worker = worker_decision(capabilities)
      checks << check("worker", worker.blocked? ? "block" : "pass", worker_message(worker, capabilities))

      status = classify(checks)
      Result.new(
        status:, summary: summary_for(status), revision: revision.id,
        repository_size_bytes: entries.sum { |entry| entry.size.to_i }, file_count: entries.count(&:file?),
        checks:, prepare_commands: prep.commands,
        grader_commands: grade.graders.any? ? grade.graders.map(&:command) : grade_signals.candidates.map(&:run),
        required_capabilities: capabilities
      )
    rescue SyrusYml::ParseError => e
      checks << check("configuration", "block", e.message) unless checks.any? { |item| item[:key] == "configuration" && item[:level] == "block" }
      Result.new(status: "needs_configuration", summary: summary_for("needs_configuration"), revision: revision.id,
                 repository_size_bytes: entries.sum { |entry| entry.size.to_i }, file_count: entries.count(&:file?), checks:,
                 prepare_commands: [], grader_commands: [], required_capabilities: RunQueueResolver::DEFAULT_RUN_CAPABILITIES)
    end
  rescue RepositoryContent::NotFound, RepositoryContent::UnknownRevision => e
    blocked_result("needs_configuration", "access", "Default branch #{@repository.default_branch} could not be resolved: #{e.message}")
  rescue RepositoryContent::Unavailable, RepositoryContent::Unsupported => e
    blocked_result("needs_configuration", "access", "Repository content is unavailable: #{e.message}")
  end

  private

  def repository_tree(revision)
    [ @content.tree(revision), false ]
  rescue RepositoryContent::Truncated => e
    [ e.partial, true ]
  end

  def credential_check
    if @repository.app_credential_active? || @user&.github_token.present?
      check("credentials", "pass", "GitHub credentials are available for cloning and pull-request operations.")
    else
      check("credentials", "block", "No GitHub App installation or personal access token is available for this repository.")
    end
  end

  def materialize(dir, revision, entries)
    paths = entries.filter_map do |entry|
      next unless entry.file?
      evidence_only = entry.path.match?(%r{\A(?:spec/|test/|tests/).+}) || entry.path.end_with?("_test.go")
      next unless MATERIALIZED_PATHS.include?(entry.path) || evidence_only || entry.path.match?(%r{\A\.github/workflows/.+\.ya?ml\z}) || File.basename(entry.path).match?(/\A(?:eslint\.config\.|jest\.config\.)/)
      entry.path
    end.first(250)
    paths.each do |path|
      target = Pathname.new(dir).join(path)
      target.dirname.mkpath
      if path.match?(%r{\A(?:spec/|test/|tests/).+}) || path.end_with?("_test.go")
        target.write("")
      else
        blob = @content.read(revision, path)
        target.binwrite(blob.bytes)
      end
    rescue RepositoryContent::NotFound
      next
    end
  end

  def parse_config(dir, checks)
    path = Pathname.new(dir).join(SyrusYml::CONFIG_FILE)
    unless path.exist?
      checks << check("configuration", "warning", ".syrus.yml is absent; prepare commands are inferred and therefore advisory.")
      return nil
    end
    SyrusYml.load_file(path).tap { checks << check("configuration", "pass", ".syrus.yml is valid.") }
  rescue SyrusYml::ParseError => e
    checks << check("configuration", "block", e.message)
    nil
  end

  def heuristic_checks(dir, entries, prep, grade, grade_signals)
    checks = []
    checks << check("prepare", prep.error? ? "block" : (prep.guessed? ? "warning" : "pass"), prep.error || prep.note || "#{prep.commands.length} prepare command(s) configured.")
    grader_message = if grade.graders.any?
      "#{grade.graders.length} grader command(s) configured."
    elsif grade_signals.candidates.any?
      "No graders are configured; #{grade_signals.candidates.length} likely command(s) were inferred as advisory suggestions."
    else
      "No grader commands were configured or detected."
    end
    checks << check("graders", grade.graders.empty? ? "warning" : "pass", grader_message)
    text = MATERIALIZED_PATHS.filter_map { |path| Pathname.new(dir).join(path).read if Pathname.new(dir).join(path).file? }.join("\n")
    SYSTEM_HINTS.each do |pattern, message|
      checks << check("environment", "warning", message) if text.match?(pattern)
    end
    version_files = entries.map(&:path) & %w[.ruby-version .node-version .python-version .tool-versions mise.toml]
    checks << check("versions", "pass", "Version declarations: #{version_files.join(', ')}.") if version_files.any?
    checks
  end

  def required_capabilities(config)
    values = [ config&.project&.capabilities, *Array(config&.targets).map(&:capabilities), *Array(config&.grade&.steps).map(&:capabilities) ].compact
    merged = values.each_with_object({}) do |capabilities, result|
      capabilities.to_h.each { |dimension, required| result[dimension.to_s] = (Array(result[dimension.to_s]) + Array(required)).map(&:to_s).uniq }
    end
    WorkerCapabilities.normalize(merged.presence || RunQueueResolver::DEFAULT_RUN_CAPABILITIES)
  end

  def worker_decision(capabilities)
    workflow = Struct.new(:trigger_kind, :planned_execution_capabilities, :worker_storage_key, :worker_hostname, :job).new("initial", capabilities, nil, nil, nil)
    step = Struct.new(:placement_policy, :details, :kind).new(Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE, {}, "implement")
    RunQueueResolver.resolve_candidate(workflow:, step:)
  end

  def worker_message(decision, capabilities)
    prefix = decision.blocked? ? "No live worker satisfies" : "A live worker satisfies"
    "#{prefix} #{capabilities.map { |key, values| "#{key}=#{Array(values).join('/')}" }.join(', ')}. Proposed queue: #{decision.queue_name}."
  end

  def classify(checks)
    return "needs_configuration" if checks.any? { |item| item[:level] == "block" && item[:key] != "worker" }
    return "incompatible" if checks.any? { |item| item[:key] == "worker" && item[:level] == "block" }
    return "ready_with_warnings" if checks.any? { |item| item[:level] == "warning" }
    "ready"
  end

  def summary_for(status)
    { "ready" => "Ready", "ready_with_warnings" => "Ready with warnings", "needs_configuration" => "Needs configuration", "incompatible" => "Incompatible" }.fetch(status)
  end

  def check(key, level, message) = { key:, level:, message: }

  def size_message(entries, truncated)
    bytes = entries.sum { |entry| entry.size.to_i }
    suffix = truncated ? " (partial tree)" : ""
    "#{entries.count(&:file?)} files, #{ActiveSupport::NumberHelper.number_to_human_size(bytes)}#{suffix}."
  end

  def blocked_result(status, key, message)
    Result.new(status:, summary: summary_for(status), revision: nil, repository_size_bytes: nil, file_count: nil,
               checks: [ check(key, "block", message) ], prepare_commands: [], grader_commands: [],
               required_capabilities: RunQueueResolver::DEFAULT_RUN_CAPABILITIES)
  end
end
