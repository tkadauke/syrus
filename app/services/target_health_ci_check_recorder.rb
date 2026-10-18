require "tmpdir"

class TargetHealthCiCheckRecorder
  def self.record!(...) = new.record!(...)

  def record!(job:, head_sha:, detail:, checked_at: Time.current, graph: nil, workspace_path: nil)
    checks = completed_checks(detail) + pending_checks(detail)
    return [] if checks.empty? || head_sha.blank?

    with_graph(job: job, head_sha: head_sha, graph: graph, workspace_path: workspace_path) do |resolved_graph, resolved_workspace_path|
      index = TargetIndex.new(resolved_graph)

      checks.group_by { |check| index.target_for(check) }.filter_map do |target, target_checks|
        next unless target

        record_checks!(
          job: job,
          head_sha: head_sha,
          checks: target_checks,
          target: target,
          graph: resolved_graph,
          workspace_path: resolved_workspace_path,
          checked_at: checked_at
        )
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[TargetHealthCiCheckRecorder] failed for #{job&.slug || 'unknown job'}: #{e.class}: #{e.message}")
    []
  end

  private

  def completed_checks(detail)
    normalized_checks(detail[:completed_checks] || detail["completed_checks"])
  end

  def pending_checks(detail)
    normalized_checks(detail[:pending_checks] || detail["pending_checks"])
  end

  def normalized_checks(checks)
    Array(checks).map { |check| check.to_h.deep_stringify_keys }
  end

  def with_graph(job:, head_sha:, graph:, workspace_path:)
    return yield(graph, workspace_path) if graph && workspace_path

    Dir.mktmpdir("target-health-ci-") do |dir|
      archive_repository_at!(job: job, head_sha: head_sha, dir: dir)
      yield(TargetGraph::Compiler.compile(dir), dir)
    end
  end

  def archive_repository_at!(job:, head_sha:, dir:)
    bare_clone = RepositoryBareClone.new(job.repository)
    bare_clone.sync!(user: job.user)

    git_capture = ProcessRunner.new(
      env: {}, command: [ "git", "--git-dir", bare_clone.path.to_s, "archive", head_sha ],
      mounts: ProcessRunner.mounts(dir, read_only: [ bare_clone.path ]), network: "grader",
      timeout: GitRunner::DEFAULT_TIMEOUT, kind: "git", job: job
    ).capture(limit: 1.gigabyte)
    raise "git archive failed: #{git_capture.stderr.presence || git_capture.result.exit_status}" unless git_capture.success?

    archive = git_capture.stdout
    extract_archive!(archive, dir, job: job)
  end

  def extract_archive!(archive, dir, job: nil)
    capture = ProcessRunner.new(
      env: {}, command: [ "tar", "-x", "-C", dir ],
      mounts: ProcessRunner.mounts(dir), network: "grader", timeout: 10.minutes,
      stdin_data: archive, kind: "archive", job: job
    ).capture
    raise "tar extract failed: #{capture.stderr.presence || capture.result.exit_status}" unless capture.success?
  end

  def record_checks!(job:, head_sha:, checks:, target:, graph:, workspace_path:, checked_at:)
    fingerprints = TargetGraph::Fingerprints.for_target(
      workspace_path: workspace_path,
      graph: graph,
      label: target.label
    )

    TargetHealthRecorder.record!(
      repository: job.repository,
      target_label: target.label.to_s,
      project_id: target.project_id,
      commit_sha: head_sha,
      input_fingerprint: fingerprints.input_fingerprint,
      command_fingerprint: fingerprints.command_fingerprint,
      environment_fingerprint: fingerprints.environment_fingerprint,
      status: aggregate_status(checks),
      checked_at: checked_at,
      artifacts: artifacts_for(checks),
      metadata: metadata_for(checks: checks, target: target, fingerprints: fingerprints)
    )
  end

  def aggregate_status(checks)
    checks.map { |check| ConclusionStatus.for(check["conclusion"]) }.max.status
  end

  def artifacts_for(checks)
    check = worst_check(checks)
    {
      "summary" => check["summary"],
      "html_url" => check["html_url"] || check["url"],
      "checks" => checks.map { |entry| artifacts_for_single_check(entry) }
    }.compact
  end

  def artifacts_for_single_check(check)
    {
      "name" => check["name"],
      "conclusion" => check["conclusion"],
      "summary" => check["summary"],
      "html_url" => check["html_url"] || check["url"]
    }.compact
  end

  def metadata_for(checks:, target:, fingerprints:)
    check = worst_check(checks)
    {
      "health_source" => "ci_check",
      "provenance" => "ci_check",
      "check_name" => check["name"],
      "check_status" => check["status"],
      "check_conclusion" => check["conclusion"],
      "check_url" => check["html_url"] || check["url"],
      "check_app_slug" => check["app_slug"],
      "check_names" => checks.map { |entry| entry["name"] },
      "check_statuses" => checks.to_h { |entry| [ entry["name"], entry["status"] ] },
      "check_conclusions" => checks.to_h { |entry| [ entry["name"], entry["conclusion"] ] },
      "target_kind" => target.kind,
      "fingerprint_metadata" => fingerprints.metadata
    }.compact
  end

  def worst_check(checks)
    checks.max_by { |check| ConclusionStatus.for(check["conclusion"]) }
  end

  class TargetIndex
    def initialize(graph)
      @targets = graph.targets.values
      @explicit = explicit_check_names
      @fallback = fallback_check_names
    end

    def target_for(check)
      name = check["name"].to_s
      @explicit[name] || @fallback[name]
    end

    private

    def explicit_check_names
      @targets.each_with_object({}) do |target, index|
        check_names_for(target).each do |name|
          index[name] ||= target
        end
      end
    end

    def fallback_check_names
      executable_targets.each_with_object({}) do |target, index|
        names = [ target.label.to_s, target.label.name ]
        names << target.label.name.delete_prefix("grade/") if target.kind == "grader"
        names.each do |name|
          next if @explicit.key?(name)
          next if index.key?(name)

          index[name] = target
        end
      end
    end

    def executable_targets
      @targets.select { |target| %w[grader repo_check builder].include?(target.kind) && target.executable? }
    end

    def check_names_for(target)
      raw = target.metadata["ci_checks"] || target.metadata["ci_check_names"] || target.metadata["github_checks"]
      Array(raw).map(&:to_s).map(&:strip).reject(&:blank?)
    end
  end

  class ConclusionStatus
    include Comparable

    PASSING = %w[success neutral].freeze
    FAILED = %w[failure action_required].freeze
    PRIORITY = {
      "passed" => 0,
      "skipped" => 1,
      "inconclusive" => 2,
      "cancelled" => 3,
      "stale" => 4,
      "timed_out" => 5,
      "failed" => 6
    }.freeze

    def self.for(conclusion) = new(conclusion)

    def initialize(conclusion)
      @conclusion = conclusion.to_s
    end

    def <=>(other)
      PRIORITY.fetch(status) <=> PRIORITY.fetch(other.status)
    end

    def status = target_health_status

    def target_health_status
      return "passed" if PASSING.include?(@conclusion)
      return "failed" if FAILED.include?(@conclusion)
      return "timed_out" if @conclusion == "timed_out"
      return "stale" if @conclusion == "stale"
      return "cancelled" if @conclusion == "cancelled"
      return "skipped" if @conclusion == "skipped"

      "inconclusive"
    end
  end
end
