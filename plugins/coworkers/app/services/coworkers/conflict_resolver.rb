require "json"
require "yaml"

# Invokes a conflict-resolution agent inside a temporary merge checkout whose
# deterministic `git merge` stopped on semantic conflicts, then validates the
# agent's tree before anything is committed. It never pushes: the caller only
# advances the persistent branch when the returned outcome is resolved.
class Coworkers::ConflictResolver
  MAX_ATTEMPTS = 2
  AGENT_TIMEOUT = 10.minutes.to_i
  AGENT_MAX_TURNS = 40
  CONTEXT_FILES = %w[SOUL.md MEMORY.md AGENTS.md .gitattributes].freeze
  CONTEXT_FILE_BYTES = 8.kilobytes
  STAGE_BYTES = 24.kilobytes
  MARKER_START = /^<{7}(?: |$)/
  MARKER_END = /^>{7}(?: |$)/

  Outcome = Data.define(:resolved, :detail, :attempts, :files, :home_sha, :source_sha) do
    def resolved? = resolved
  end

  class << self
    # Test seam, mirroring RunJob.agent_runner: a callable taking
    # (workspace_path:, prompt:) that edits the checkout and returns an
    # AgentInvocation-shaped result.
    attr_accessor :agent
  end

  def initialize(coworker:, user:, git: GitRunner.new, env: {}, timeout: nil)
    @coworker = coworker
    @user = user
    @git = git
    @env = env
    @timeout = timeout
  end

  def available?
    return true if self.class.agent
    return false unless @user.respond_to?(:agent_provider) && @user.agent_provider.present?

    @user.agent_provider_configured?(@user.agent_provider)
  end

  def call(dir:)
    files = git("diff", "--name-only", "--diff-filter=U", chdir: dir).lines.map(&:strip).reject(&:blank?)
    home_sha = git("rev-parse", "HEAD", chdir: dir).strip
    source_sha = git("rev-parse", "MERGE_HEAD", chdir: dir).strip
    context = gather_context(dir, files:, home_sha:, source_sha:)

    failure = nil
    attempts = 0
    MAX_ATTEMPTS.times do
      attempts += 1
      failure = run_agent(dir, prompt(context, failure))
      failure ||= validate(dir, files)
      break if failure.nil?
    end

    commit_merge!(dir) if failure.nil?
    Outcome.new(resolved: failure.nil?, detail: failure, attempts:, files:, home_sha:, source_sha:)
  end

  # Conflict-marker lines in supported (non-binary) text files, used both to
  # validate the agent's tree and to refuse committing marker text.
  def self.files_with_markers(root, relative_paths)
    relative_paths.select do |relative|
      file = Pathname(root).join(relative)
      next false unless file.file? && !file.symlink?

      content = File.binread(file).force_encoding(Encoding::UTF_8).scrub
      !content.include?("\0") && (content.match?(MARKER_START) || content.match?(MARKER_END))
    end
  end

  private

  def git(*args, chdir:)
    @git.run(*args, chdir: chdir.to_s, env: @env, **timeout_option)
  end

  def git_capture(*args, chdir:)
    @git.capture(*args, chdir: chdir.to_s, env: @env, **timeout_option)
  end

  def timeout_option = @timeout ? { timeout: @timeout } : {}

  def run_agent(dir, text)
    runner = self.class.agent || default_agent
    result = runner.call(workspace_path: dir.to_s, prompt: text)
    return "the agent timed out" if result.respond_to?(:timed_out) && result.timed_out
    return "the agent reported #{result.try(:outcome) || 'an error'}" if result.respond_to?(:is_error) && result.is_error
    return "the agent exited #{result.try(:exit_status)}" if result.respond_to?(:success?) && !result.success?

    nil
  rescue StandardError => error
    "the agent failed: #{error.class}: #{error.message}".first(300)
  end

  def default_agent
    provider = @user.agent_provider
    lambda do |workspace_path:, prompt:|
      AgentProviders.for(provider).invoke_one_shot(
        workspace_path:, user: @user, runner: RunJob.agent_runner, scope: "coworker-conflict-resolution",
        prompt:, log_sink: ->(*, **) { }, timeout: AGENT_TIMEOUT, max_turns: AGENT_MAX_TURNS
      )
    end
  end

  # Stages the tree, then rejects anything that is not a fully resolved,
  # well-formed result. Returns a failure description, or nil when valid.
  def validate(dir, _files)
    git("add", "--all", chdir: dir)
    unmerged = git("diff", "--name-only", "--diff-filter=U", chdir: dir).lines.map(&:strip).reject(&:blank?)
    return "Unmerged index entries remain in #{unmerged.join(', ')}." if unmerged.any?

    changed = git("diff", "--cached", "--name-only", "HEAD", chdir: dir).lines.map(&:strip).reject(&:blank?)
    markers = self.class.files_with_markers(dir, changed)
    return "Conflict markers remain in #{markers.join(', ')}." if markers.any?

    check = git_capture("diff", "--cached", "--check", "HEAD", chdir: dir)
    return "git diff --check failed: #{check.stdout}#{check.stderr}".strip.last(500) unless check.success?

    invalid = invalid_structured_files(dir, changed)
    invalid.any? ? "Structured files no longer parse: #{invalid.join(', ')}." : nil
  end

  # Targeted persistence checks: structured files the coworker relies on must
  # still parse after the merge.
  def invalid_structured_files(dir, changed)
    changed.select do |relative|
      file = Pathname(dir).join(relative)
      next false unless file.file? && !file.symlink?

      text = File.binread(file).force_encoding(Encoding::UTF_8)
      case File.extname(relative).downcase
      when ".json" then JSON.parse(text) && false
      when ".yml", ".yaml" then YAML.safe_load(text, aliases: false, permitted_classes: [ Date, Time ]) && false
      else false
      end
    rescue JSON::ParserError, Psych::Exception
      true
    end
  end

  def commit_merge!(dir)
    git("commit", "--no-edit", "--no-verify", chdir: dir)
  end

  def gather_context(dir, files:, home_sha:, source_sha:)
    base = git_capture("merge-base", home_sha, source_sha, chdir: dir).stdout.to_s.strip
    stages = files.to_h do |relative|
      [ relative, { base: stage(dir, 1, relative), home: stage(dir, 2, relative), source: stage(dir, 3, relative) } ]
    end
    rules = CONTEXT_FILES.filter_map do |name|
      file = Pathname(dir).join(name)
      next unless file.file? && !file.symlink?

      [ name, File.binread(file, CONTEXT_FILE_BYTES).force_encoding(Encoding::UTF_8).scrub ]
    end
    { base:, home_sha:, source_sha:, files:, stages:, rules: }
  end

  def stage(dir, number, relative)
    result = git_capture("show", ":#{number}:#{relative}", chdir: dir)
    return "(absent in this version)" unless result.success?

    result.stdout.to_s.byteslice(0, STAGE_BYTES).to_s.force_encoding(Encoding::UTF_8).scrub
  end

  def prompt(context, previous_failure)
    sections = context[:files].map do |relative|
      version = context[:stages].fetch(relative)
      <<~SECTION
        ### #{relative}

        Merge base version:
        ~~~~
        #{version[:base]}
        ~~~~

        Persistent home branch (parent 1, #{context[:home_sha]}):
        ~~~~
        #{version[:home]}
        ~~~~

        Incoming branch (parent 2, #{context[:source_sha]}):
        ~~~~
        #{version[:source]}
        ~~~~
      SECTION
    end
    rules = context[:rules].map { |name, content| "### #{name}\n~~~~\n#{content}\n~~~~" }.join("\n\n")
    retry_note = previous_failure ? "\nYour previous attempt was rejected: #{previous_failure}\nFix exactly that and finish the resolution.\n" : ""

    <<~PROMPT
      You are resolving a git merge conflict in the private persistent workspace of the coworker @#{@coworker.handle}.
      This workspace is the coworker's durable memory. It is private: never copy its contents anywhere outside this checkout.

      The current directory is a git checkout in the middle of `git merge`. Two parents edited the same lines
      (merge base #{context[:base]}). Resolve every conflicting file so the result preserves the compatible changes
      from BOTH parents: keep every row, bullet, and piece of evidence either side added, and only reconcile genuinely
      contradictory lines. Respect the coworker memory rules below.

      Requirements:
      - Edit the conflicting files in place so they contain no conflict markers (`<<<<<<<`, `>>>>>>>`).
      - Do not run `git commit`, `git push`, or `git merge --abort`; the harness validates and commits the result.
      - Do not touch files that are not conflicting unless needed to keep the result consistent.
      - Keep Markdown tables well-formed and structured files (JSON/YAML) parseable; leave no trailing whitespace you introduced.

      Conflicting files: #{context[:files].join(', ')}
      #{retry_note}
      ## Conflicting versions

      #{sections.join("\n")}
      ## Coworker memory rules and context

      #{rules.presence || '(none)'}
    PROMPT
  end
end
