module SyrusCoverage
  # The "Test coverage" section of the agent environment snapshot: the
  # repository's configured thresholds and the latest coverage figures, so an
  # implementing agent knows the bar before it writes tests.
  class AgentContext
    def initialize(run:, workspace_path:, repository:)
      @run = run
      @workspace_path = workspace_path
      @repository = repository
    end

    def lines_for_prompt = lines

    private

    attr_reader :workspace_path, :repository

  def lines
    return [] unless workspace_path&.directory? && @run

    coverage_plan = begin
      Syrus::Host::SyrusYmlConfig.load_repo(workspace_path).plugin_configurations[SyrusCoverage::RepositoryConfiguration::KEY]
    rescue StandardError
      nil
    end
    return [] unless coverage_plan

    lines = [ "## Test coverage", coverage_config_line(coverage_plan) ]

    artifact, source_label = find_coverage_data
    if artifact
      lines << "Last run: #{format_coverage_summary(artifact)} (#{source_label})"
      lines << coverage_miss_warning(artifact) if artifact["threshold_miss"]
      uncovered = coverage_uncovered_files(artifact)
      if uncovered.any?
        lines << "Low-coverage changed files:"
        uncovered.each do |entry|
          count = entry[:count]
          lines << "  - #{entry[:file]} (#{entry[:pct]} — #{count} uncovered changed line#{count == 1 ? '' : 's'})"
        end
      end
    else
      lines << "Last run: no coverage data yet"
    end

    lines
  end

  def coverage_config_line(plan)
    parts = []
    if plan.threshold
      parts << "lines ≥#{format_coverage_pct(plan.threshold.lines)}%" if plan.threshold.lines
      parts << "PR delta ≥#{format_coverage_pct(plan.threshold.pr_lines)}%" if plan.threshold.pr_lines
    end
    config = parts.empty? ? "no thresholds configured" : parts.join(", ")
    "Configured: #{config} (on_miss: #{plan.on_miss})"
  end

  def find_coverage_data
    @run.job.workflows.reorder(created_at: :desc).each do |w|
      artifact = SyrusCoverage::Artifact.read(w)
      next unless artifact.present? && !artifact["coverage_unavailable"]

      age = coverage_age_label(w.created_at)
      return [ artifact, "#{w.slug}, #{age}" ]
    end

    snapshot = SyrusCoverage::Snapshot
      .where(repository: repository)
      .on_default_branch
      .recent(1)
      .first
    return [ nil, nil ] unless snapshot

    artifact = {
      "summary" => {
        "lines_pct"   => snapshot.lines_pct,
        "branches_pct" => snapshot.branches_pct
      }
    }
    [ artifact, "default branch, #{coverage_age_label(snapshot.created_at)}" ]
  end

  def format_coverage_summary(artifact)
    summary = artifact["summary"] || {}
    parts = []
    parts << "lines #{format_coverage_pct(summary["lines_pct"])}%" if summary["lines_pct"]
    parts << "branches #{format_coverage_pct(summary["branches_pct"])}%" if summary["branches_pct"]
    parts.empty? ? "no data" : parts.join(", ")
  end

  def coverage_miss_warning(artifact)
    details = artifact["threshold_miss_details"] || {}
    parts = []
    if details["lines_pct"] && details["threshold_lines"] && details["lines_pct"] < details["threshold_lines"]
      parts << "lines #{format_coverage_pct(details["lines_pct"])}% < #{format_coverage_pct(details["threshold_lines"])}%"
    end
    if details["pr_delta_pct"] && details["threshold_pr_lines"] && details["pr_delta_pct"] < details["threshold_pr_lines"]
      parts << "PR delta #{format_coverage_pct(details["pr_delta_pct"])}% < #{format_coverage_pct(details["threshold_pr_lines"])}%"
    end
    miss_str = parts.any? ? parts.join(", ") : "see artifact for details"
    "⚠️  Threshold miss: #{miss_str}"
  end

  def coverage_uncovered_files(artifact)
    diff_annotations = artifact["diff_annotations"] || {}
    files = artifact["files"] || {}

    result = diff_annotations.filter_map do |filepath, lines_map|
      uncovered_count = lines_map.values.count { |status| status == "uncovered" }
      next if uncovered_count == 0

      file_pct = files.dig(filepath, "lines_pct")
      pct_str = file_pct ? "#{file_pct.round}%" : "coverage unknown"
      { file: filepath, pct: pct_str, count: uncovered_count }
    end

    result.sort_by { |entry| [ -entry[:count], entry[:file] ] }
  end

  def format_coverage_pct(value)
    return "?" unless value

    format("%.1f", value).sub(/\.0$/, "")
  end

  def coverage_age_label(time)
    return "unknown time" unless time

    seconds = (Time.current - time).to_i.abs
    if seconds < 60
      "just now"
    elsif seconds < 3600
      mins = seconds / 60
      "#{mins} minute#{mins == 1 ? '' : 's'} ago"
    elsif seconds < 86400
      hours = seconds / 3600
      "#{hours} hour#{hours == 1 ? '' : 's'} ago"
    else
      days = seconds / 86400
      "#{days} day#{days == 1 ? '' : 's'} ago"
    end
  end
  end
end
