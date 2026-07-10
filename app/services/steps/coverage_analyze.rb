module Steps
  # Non-agentic step that runs after grader_collect in coverage-enabled workflows.
  # Parses coverage artifacts produced by graders, merges and normalizes them,
  # computes diff annotations against the PR, stores the coverage artifact on
  # the Workflow, uploads a temporary hit map blob, creates a CoverageSnapshot,
  # and evaluates the configured threshold.
  class CoverageAnalyze < Base
    def call
      workspace.setup
      plan = RepoCoveragePlan.for(workspace.path)

      unless plan
        log("[coverage_analyze] no coverage configuration in .syrus.yml — skipping")
        return
      end

      parsed_sources = parse_sources(plan)
      found_sources  = parsed_sources.select(&:found)

      if found_sources.empty?
        log("[coverage_analyze] no coverage artifacts found — marking coverage unavailable")
        Workflow::CoverageArtifact.write!(workflow, { "coverage_unavailable" => true,
                                                      "sources_status" => sources_status(parsed_sources) })
        return
      end

      merged     = CoverageAnalysis::MergeStrategy.merge_all(found_sources.map(&:raw))
      normalized = CoverageAnalysis::Normalizer.normalize(merged)

      diff_annotations, pr_delta = compute_diff_coverage(normalized[:hit_map])

      artifact = build_artifact(normalized, diff_annotations, pr_delta, plan, parsed_sources)
      Workflow::CoverageArtifact.write!(workflow, artifact)
      log("[coverage_analyze] lines #{artifact.dig('summary', 'lines_pct')}%  PR delta #{pr_delta['pct']}%")

      attach_hit_map(normalized[:hit_map], plan.hitmap_ttl_days)

      upsert_snapshot(normalized, pr_delta)

      handle_threshold(plan, artifact)
    end

    private

    def parse_sources(plan)
      plan.sources.map do |source|
        artifact_path = workspace.path.join(source.artifact)
        unless artifact_path.exist?
          log("[coverage_analyze] artifact not found: #{source.artifact}")
          next CoverageAnalysis::ParsedSource.new(artifact: source.artifact, format: source.format,
                                          found: false, raw: nil, lines_pct: nil)
        end

        begin
          result = CoverageAnalysis::Parsers.for(source.format).parse(artifact_path.read)
          CoverageAnalysis::ParsedSource.new(artifact: source.artifact, format: source.format,
                                     found: true, raw: result.raw, lines_pct: result.lines_pct)
        rescue => e
          log("[coverage_analyze] failed to parse #{source.artifact} (#{source.format}): #{e.message}")
          CoverageAnalysis::ParsedSource.new(artifact: source.artifact, format: source.format,
                                     found: false, raw: nil, lines_pct: nil)
        end
      end
    end

    def compute_diff_coverage(hit_map)
      diff_text = GitRunner.new.run(
        "diff", "#{default_branch_ref}...HEAD", "--unified=0",
        chdir: workspace.path.to_s
      )
      CoverageAnalysis::DiffAnnotator.annotate(diff_text, hit_map)
    rescue GitRunner::GitError => e
      log("[coverage_analyze] git diff failed: #{e.message} — skipping diff annotations")
      [ {}, { "covered" => 0, "total" => 0, "pct" => nil, "uncovered_files" => [] } ]
    end

    def build_artifact(normalized, diff_annotations, pr_delta, plan, parsed_sources)
      artifact = {
        "summary"          => normalized[:summary],
        "files"            => normalized[:files],
        "diff_annotations" => diff_annotations,
        "pr_delta"         => pr_delta,
        "sources_status"   => sources_status(parsed_sources),
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

      if plan.pr_comment
        artifact["pr_comment_body"] = CoverageReport::PrCommentFormatter.new(artifact, plan: plan).format
      end

      artifact
    end

    def sources_status(parsed_sources)
      parsed_sources.map do |s|
        { "artifact" => s.artifact, "found" => s.found, "lines_pct" => s.lines_pct }
      end
    end

    def attach_hit_map(hit_map, ttl_days)
      workflow.attach_coverage_hit_map!(hit_map)
      workflow.set_artifact!("coverage", workflow.artifact("coverage").merge("hit_map_attached" => true))
      CoverageHitMapPruneJob.set(wait: ttl_days.days).perform_later(workflow.id)
      log("[coverage_analyze] hit map attached (TTL #{ttl_days}d)")
    rescue => e
      Rails.logger.warn("[CoverageAnalyze] hit map attach failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    def upsert_snapshot(normalized, pr_delta)
      sha     = head_sha
      branch  = job.branch_name.presence || repository.default_branch
      summary = normalized[:summary]

      CoverageSnapshot.create!(
        repository:   repository,
        workflow:     workflow,
        job:          job,
        sha:          sha,
        branch:       branch,
        lines_pct:    summary["lines_pct"],
        branches_pct: summary["branches_pct"],
        functions_pct: summary["functions_pct"],
        pr_delta_pct: pr_delta["pct"],
        file_count:   normalized[:files].size,
        data:         normalized[:files]
      )
    rescue => e
      Rails.logger.warn("[CoverageAnalyze] snapshot creation failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    end

    def handle_threshold(plan, artifact)
      return unless artifact["threshold_miss"]

      details = artifact["threshold_miss_details"] || {}
      msg = "Coverage threshold not met: " \
            "#{details['lines_pct']}% lines (threshold: #{details['threshold_lines']}%)"

      case plan.on_miss
      when "block"
        log("[coverage_analyze] threshold miss — failing step")
        raise StepFailed, msg
      when "schedule"
        CoverageScheduleTriggerJob.perform_later(workflow.id)
        log("[coverage_analyze] threshold miss — scheduled coverage fix job")
      else
        log("[coverage_analyze] threshold miss — warning only (on_miss: #{plan.on_miss})")
      end
    end
  end
end
