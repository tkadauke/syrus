module Steps
  # Non-agentic step that runs after grader_collect in coverage-enabled workflows.
  # Parses coverage artifacts produced by graders, merges and normalizes them,
  # computes diff annotations against the PR, stores the coverage artifact on
  # the Workflow, uploads a temporary hit map blob, creates a CoverageSnapshot,
  # and evaluates the configured threshold.
  class CoverageAnalyze < Base
    def call
      workspace.setup
      diff_text = diff_text_for_coverage
      plan_result = App::CoverageProjects.call(workspace_path: workspace.path, changed_files: changed_files_from_diff(diff_text))
      plans = plan_result.plans

      if plans.empty?
        log("[coverage_analyze] no coverage configuration in .syrus.yml — skipping")
        return
      end

      project_artifacts = plans.map { |plan| analyze_plan(plan, diff_text) }
      found_project_artifacts = project_artifacts.reject { |artifact| artifact["coverage_unavailable"] }

      if found_project_artifacts.empty?
        log("[coverage_analyze] no coverage artifacts found — marking coverage unavailable")
        Workflow::CoverageArtifact.write!(workflow, {
          "coverage_unavailable" => true,
          "projects" => project_artifacts,
          "sources_status" => project_artifacts.flat_map { |artifact| artifact["sources_status"] || [] }
        })
        return
      end

      artifact = aggregate_artifact(found_project_artifacts, project_artifacts, plans, diff_text)
      Workflow::CoverageArtifact.write!(workflow, persisted_artifact(artifact))
      log("[coverage_analyze] analyzed #{found_project_artifacts.size} coverage project(s)")

      attach_hit_map(merged_hit_map(found_project_artifacts), plans.map(&:hitmap_ttl_days).max)

      found_project_artifacts.each do |project_artifact|
        plan = plans.find { |candidate| candidate.project_id == project_artifact.dig("project", "id") }
        upsert_snapshot(project_artifact, plan)
        handle_threshold(plan, project_artifact)
        record_branches_threshold_warning(plan, project_artifact)
      end
    end

    private

    def analyze_plan(plan, diff_text)
      parsed_sources = parse_sources(plan)
      found_sources = parsed_sources.select(&:found)
      project = project_payload(plan)

      if found_sources.empty?
        log("[coverage_analyze] no coverage artifacts found for #{plan.project_label}")
        return {
          "coverage_unavailable" => true,
          "project" => project,
          "sources_status" => sources_status(parsed_sources, plan)
        }
      end

      merged = CoverageAnalysis::MergeStrategy.merge_all(found_sources.map(&:raw))
      normalized = CoverageAnalysis::Normalizer.normalize(merged)
      diff_annotations, pr_delta = compute_diff_coverage(normalized[:hit_map], diff_text)
      artifact = build_project_artifact(normalized, diff_annotations, pr_delta, plan, parsed_sources)

      log("[coverage_analyze] #{plan.project_label}: lines #{artifact.dig('summary', 'lines_pct')}%  PR delta #{pr_delta['pct']}%")
      artifact
    end

    def parse_sources(plan)
      plan.sources.map do |source|
        artifact_path = coverage_artifact_path(plan, source)
        unless artifact_path.exist?
          log("[coverage_analyze] artifact not found: #{source_status_path(plan, source)}")
          next CoverageAnalysis::ParsedSource.new(artifact: source_status_path(plan, source), format: source.format,
                                          found: false, raw: nil, lines_pct: nil)
        end

        begin
          result = try_plugin_parsers(artifact_path, source.format) ||
                   CoverageAnalysis::Parsers.for(source.format).parse(artifact_path.read)
          normalized_raw = normalize_hit_map_paths(result.raw, plan)
          CoverageAnalysis::ParsedSource.new(artifact: source_status_path(plan, source), format: source.format,
                                     found: true, raw: normalized_raw, lines_pct: result.lines_pct)
        rescue => e
          log("[coverage_analyze] failed to parse #{source_status_path(plan, source)} (#{source.format}): #{e.message}")
          CoverageAnalysis::ParsedSource.new(artifact: source_status_path(plan, source), format: source.format,
                                     found: false, raw: nil, lines_pct: nil)
        end
      end
    end

    def try_plugin_parsers(artifact_path, format)
      Syrus::PluginRegistry.providers_for(:coverage_analyzer).each do |provider|
        result = PerformanceLogging.plugin_call(extension_point: :coverage_analyzer, provider: provider, operation: :call) do
          provider.call(artifact_path: artifact_path, format_hint: format)
        end
        return result if result
      end
      nil
    end

    def compute_diff_coverage(hit_map, diff_text)
      CoverageAnalysis::DiffAnnotator.annotate(diff_text, hit_map)
    end

    def diff_text_for_coverage
      GitRunner.new.run(
        "diff", "#{default_branch_ref}...HEAD", "--unified=0",
        chdir: workspace.path.to_s
      )
    rescue GitRunner::GitError => e
      log("[coverage_analyze] git diff failed: #{e.message} — skipping diff annotations")
      ""
    end

    def changed_files_from_diff(diff_text)
      diff_text.scan(/^diff --git a\/(.+?) b\/.+$/).flatten.uniq
    end

    def build_project_artifact(normalized, diff_annotations, pr_delta, plan, parsed_sources)
      artifact = {
        "project" => project_payload(plan),
        "summary"          => normalized[:summary],
        "files"            => normalized[:files],
        "hit_map"          => normalized[:hit_map],
        "diff_annotations" => diff_annotations,
        "pr_delta"         => pr_delta,
        "sources_status"   => sources_status(parsed_sources, plan),
        "hit_map_attached" => false
      }

      lines_pct    = artifact.dig("summary", "lines_pct")
      pr_delta_pct = pr_delta["pct"]

      if plan.threshold_miss?(lines_pct: lines_pct, pr_delta_pct: pr_delta_pct)
        artifact["threshold_miss"] = true
        artifact["threshold_miss_details"] = {
          "lines_pct"        => lines_pct,
          "threshold_lines"  => plan.threshold&.lines,
          "pr_delta_pct"     => pr_delta_pct,
          "threshold_pr_lines" => plan.threshold&.pr_lines
        }
      end

      artifact
    end

    def aggregate_artifact(found_project_artifacts, project_artifacts, plans, diff_text)
      root = found_project_artifacts.find { |artifact| artifact.dig("project", "id") == TargetGraph::ROOT_PROJECT_ID }
      aggregate = root ? root.except("project") : repository_aggregate(found_project_artifacts, diff_text)
      aggregate["projects"] = project_artifacts
      aggregate["sources_status"] = project_artifacts.flat_map { |artifact| artifact["sources_status"] || [] }
      aggregate["hit_map_attached"] = false

      comment_plans = plans.select(&:pr_comment)
      if comment_plans.any?
        aggregate["pr_comment_body"] = CoverageReport::PrCommentFormatter.new(aggregate, plans: comment_plans).format
      end

      aggregate
    end

    def repository_aggregate(found_project_artifacts, diff_text)
      normalized = CoverageAnalysis::Normalizer.normalize(
        CoverageAnalysis::MergeStrategy.merge_all(found_project_artifacts.map { |artifact| denormalized_project_artifact(artifact) })
      )
      diff_annotations, pr_delta = compute_diff_coverage(normalized[:hit_map], diff_text)

      {
        "summary" => normalized[:summary],
        "files" => normalized[:files],
        "diff_annotations" => diff_annotations,
        "pr_delta" => pr_delta
      }
    end

    def denormalized_project_artifact(artifact)
      files = artifact["files"] || {}
      {
        hit_map: artifact["hit_map"] || {},
        lf: files.values.sum { |stats| stats["line_count"].to_i },
        lh: files.values.sum { |stats| stats["covered_line_count"].to_i },
        brf: files.values.sum { |stats| stats["branch_count"].to_i },
        brh: files.values.sum { |stats| stats["covered_branch_count"].to_i },
        file_stats: files.transform_values do |stats|
          {
            lf: stats["line_count"].to_i,
            lh: stats["covered_line_count"].to_i,
            brf: stats["branch_count"].to_i,
            brh: stats["covered_branch_count"].to_i
          }
        end
      }
    end

    def sources_status(parsed_sources, plan)
      parsed_sources.map do |s|
        {
          "artifact" => s.artifact,
          "found" => s.found,
          "lines_pct" => s.lines_pct,
          "project_id" => plan.project_id,
          "project_label" => plan.project_label,
          "target_label" => plan.target_label
        }
      end
    end

    def normalize_hit_map_paths(raw, plan)
      prefix = workspace.path.to_s + "/"
      hit_map    = raw[:hit_map].transform_keys    { |k| normalize_coverage_path(k, prefix, plan) }
      file_stats = raw[:file_stats].transform_keys { |k| normalize_coverage_path(k, prefix, plan) }
      raw.merge(hit_map: hit_map, file_stats: file_stats)
    end

    def attach_hit_map(hit_map, ttl_days)
      workflow.attach_coverage_hit_map!(hit_map)
      workflow.set_artifact!("coverage", mark_hit_map_attached(workflow.artifact("coverage")))
      CoverageHitMapPruneJob.set(wait: ttl_days.days).perform_later(workflow.id)
      log("[coverage_analyze] hit map attached (TTL #{ttl_days}d)")
    rescue => e
      Rails.logger.warn("[CoverageAnalyze] hit map attach failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    def upsert_snapshot(artifact, plan)
      sha     = head_sha
      branch  = job.branch_name.presence || repository.default_branch
      summary = artifact["summary"] || {}

      CoverageSnapshot.create!(
        repository:   repository,
        workflow:     workflow,
        job:          job,
        project_id: plan.project_id,
        project_label: plan.project_label,
        target_label: plan.target_label,
        sha:          sha,
        branch:       branch,
        lines_pct:    summary["lines_pct"],
        branches_pct: summary["branches_pct"],
        functions_pct: summary["functions_pct"],
        pr_delta_pct: artifact.dig("pr_delta", "pct"),
        file_count:   artifact.fetch("files", {}).size,
        data:         artifact["files"]
      )
    rescue => e
      Rails.logger.warn("[CoverageAnalyze] snapshot creation failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    def handle_threshold(plan, artifact)
      return unless artifact["threshold_miss"]

      details = artifact["threshold_miss_details"] || {}
      msg = "Coverage threshold not met " \
            "(lines: #{details['lines_pct']}%, threshold: #{details['threshold_lines']}%). " \
            "Add tests and retry this Job."

      CoverageOnMiss.for(plan.on_miss).call(workflow: workflow, on_miss: plan.on_miss, message: msg, log: method(:log))
    end

    # Branch coverage never hard-fails via `on_miss` — unlike lines/pr_lines,
    # it always records an actionable WorkflowWarning instead (see
    # config/syrus_docs/workflow_warnings.md and coverage.md).
    def record_branches_threshold_warning(plan, artifact)
      branches_pct = artifact.dig("summary", "branches_pct")
      return unless plan.branches_threshold_miss?(branches_pct: branches_pct)

      threshold_branches = plan.threshold.branches

      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "coverage_branches_threshold_miss",
        severity: "medium",
        title: "Branch coverage #{branches_pct}% is below the #{threshold_branches}% threshold",
        evidence: { "branches_pct" => branches_pct, "threshold_branches" => threshold_branches },
        suggested_prompt: branches_threshold_prompt(branches_pct: branches_pct, threshold_branches: threshold_branches)
      )
      log("[coverage_analyze] branch coverage threshold miss — recorded warning (#{branches_pct}% < #{threshold_branches}%)")
    rescue StandardError => e
      Rails.logger.warn("[CoverageAnalyze] failed to record branches threshold warning for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    def branches_threshold_prompt(branches_pct:, threshold_branches:)
      <<~PROMPT.strip
        Branch coverage is #{branches_pct}%, below the configured threshold of #{threshold_branches}% (`coverage.threshold.branches` in `.syrus.yml`). Add tests that exercise the untested branches (conditionals, guard clauses, rescue paths) to raise branch coverage above the threshold.
      PROMPT
    end

    def project_payload(plan)
      {
        "id" => plan.project_id,
        "label" => plan.project_label,
        "path" => plan.project_path,
        "coverage_base_path" => plan.coverage_base_path,
        "owner_config_path" => plan.owner_config_path,
        "target_label" => plan.target_label
      }
    end

    def coverage_artifact_path(plan, source)
      return workspace.path.join(source.artifact) if plan.coverage_base_path.blank?

      workspace.path.join(plan.coverage_base_path, source.artifact)
    end

    def source_status_path(plan, source)
      return source.artifact if plan.coverage_base_path.blank?

      "#{plan.coverage_base_path}/#{source.artifact}"
    end

    def normalize_coverage_path(path, workspace_prefix, plan)
      path = path.to_s
      return path.delete_prefix(workspace_prefix) if path.start_with?(workspace_prefix)
      return path if plan.coverage_base_path.blank?
      return path if path == plan.coverage_base_path || path.start_with?("#{plan.coverage_base_path}/")

      "#{plan.coverage_base_path}/#{path}"
    end

    def merged_hit_map(project_artifacts)
      project_artifacts.each_with_object({}) do |artifact, merged|
        (artifact["hit_map"] || {}).each { |path, lines| merged[path] = lines }
      end
    end

    def persisted_artifact(artifact)
      artifact.except("hit_map").tap do |persisted|
        persisted["projects"] = Array(artifact["projects"]).map { |project| project.except("hit_map") } if artifact["projects"]
      end
    end

    def mark_hit_map_attached(artifact)
      artifact = artifact.merge("hit_map_attached" => true)
      return artifact unless artifact["projects"].is_a?(Array)

      artifact.merge(
        "projects" => artifact["projects"].map do |project|
          project["coverage_unavailable"] ? project : project.merge("hit_map_attached" => true)
        end
      )
    end
  end
end
