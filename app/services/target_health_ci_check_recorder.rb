require "open3"
require "tmpdir"

class TargetHealthCiCheckRecorder
  def self.record!(...) = new.record!(...)

  def record!(job:, head_sha:, detail:, checked_at: Time.current, graph: nil, workspace_path: nil)
    checks = completed_checks(detail)
    return [] if checks.empty? || head_sha.blank?

    with_graph(job: job, head_sha: head_sha, graph: graph, workspace_path: workspace_path) do |resolved_graph, resolved_workspace_path|
      index = TargetIndex.new(resolved_graph)
      checks.filter_map do |check|
        target = index.target_for(check)
        next unless target

        record_check!(
          job: job,
          head_sha: head_sha,
          check: check,
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
    Array(detail[:completed_checks] || detail["completed_checks"]).map { |check| check.to_h.deep_stringify_keys }
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

    stdout, stderr, status = Open3.capture3(
      "git", "--git-dir", bare_clone.path.to_s, "archive", head_sha
    )
    raise "git archive failed: #{stderr.presence || status.exitstatus}" unless status.success?

    extract_archive!(stdout, dir)
  end

  def extract_archive!(archive, dir)
    stdout, stderr, status = Open3.capture3("tar", "-x", "-C", dir, stdin_data: archive)
    raise "tar extract failed: #{stderr.presence || status.exitstatus}" unless status.success?
  end

  def record_check!(job:, head_sha:, check:, target:, graph:, workspace_path:, checked_at:)
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
      status: status_for(check),
      checked_at: checked_at,
      artifacts: artifacts_for(check),
      metadata: metadata_for(check: check, target: target, fingerprints: fingerprints)
    )
  end

  def status_for(check)
    ConclusionStatus.for(check["conclusion"]).target_health_status
  end

  def artifacts_for(check)
    {
      "summary" => check["summary"],
      "html_url" => check["html_url"] || check["url"]
    }.compact
  end

  def metadata_for(check:, target:, fingerprints:)
    {
      "health_source" => "ci_check",
      "provenance" => "ci_check",
      "check_name" => check["name"],
      "check_status" => check["status"],
      "check_conclusion" => check["conclusion"],
      "check_url" => check["html_url"] || check["url"],
      "check_app_slug" => check["app_slug"],
      "target_kind" => target.kind,
      "fingerprint_metadata" => fingerprints.metadata
    }.compact
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
    PASSING = %w[success neutral].freeze
    FAILED = %w[failure action_required].freeze

    def self.for(conclusion) = new(conclusion)

    def initialize(conclusion)
      @conclusion = conclusion.to_s
    end

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
