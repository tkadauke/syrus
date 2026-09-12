require "open3"
require "tmpdir"

module CiRepair
  class TargetContext
    Result = Data.define(:failed_checks, :missed_edges)

    def self.call(...) = new.call(...)

    def call(job:, head_sha:, failed_checks:, graph: nil, workspace_path: nil)
      checks = Array(failed_checks).map { |check| stringify_hash(check) }
      return Result.new(failed_checks: checks, missed_edges: []) if checks.empty? || head_sha.blank?

      with_graph(job: job, head_sha: head_sha, graph: graph, workspace_path: workspace_path) do |resolved_graph, _resolved_workspace_path|
        index = TargetHealthCiCheckRecorder::TargetIndex.new(resolved_graph)
        enriched = checks.map { |check| attach_target_context(check, graph: resolved_graph, index: index) }
        Result.new(failed_checks: enriched, missed_edges: missed_edges_for(job: job, head_sha: head_sha, failed_checks: enriched))
      end
    rescue StandardError => e
      Rails.logger.warn("[CiRepair::TargetContext] failed for #{job&.slug || 'unknown job'}: #{e.class}: #{e.message}")
      Result.new(failed_checks: checks, missed_edges: [])
    end

    private

    def attach_target_context(check, graph:, index:)
      target = index.target_for(check)
      return check unless target

      check.merge("target_context" => context_for(target, graph: graph))
    end

    def context_for(target, graph:)
      project = graph.project(target.project_id)
      {
        "target_label" => target.label.to_s,
        "target_kind" => target.kind,
        "project_id" => target.project_id,
        "project_label" => project&.label,
        "project_path" => project&.path,
        "owner_config_path" => target.owner_config_path,
        "source_scope" => target.source_scope,
        "dependencies" => target.dependencies.map(&:to_s),
        "dependency_context" => dependency_context_for(target, graph: graph),
        "suggested_fixes" => suggested_fixes_for(target)
      }.compact
    end

    def dependency_context_for(target, graph:)
      graph.dependency_closure_for(target.label).filter_map do |label|
        dependency = graph.target(label)
        next unless dependency

        {
          "target_label" => dependency.label.to_s,
          "target_kind" => dependency.kind,
          "project_id" => dependency.project_id,
          "source_scope" => dependency.source_scope,
          "owner_config_path" => dependency.owner_config_path
        }.compact
      end
    end

    def suggested_fixes_for(target)
      suggestions = [
        "If this failure was caused by a dependency outside the target's source scope, add an explicit `deps:` edge to #{target.label}.",
        "If this check belongs to a nested project, move the grader or repo check into that project's `.syrus.yml` so selection uses the right scope.",
        "If this CI check is external to Syrus graders, declare an explicit target with `ci_checks:` matching the GitHub check name."
      ]
      suggestions << "If the target's source globs are too narrow, expand `sources:` in #{target.owner_config_path}." if target.owner_config_path.present?
      suggestions
    end

    def missed_edges_for(job:, head_sha:, failed_checks:)
      mapped = failed_checks.filter_map do |check|
        context = check["target_context"]
        next unless context

        [ context["target_label"], check ]
      end.to_h
      return [] if mapped.empty?

      skipped_selection_entries(job).filter_map do |entry|
        target_label = entry["target_label"].to_s
        check = mapped[target_label]
        next unless check

        missed_edge_for(job: job, head_sha: head_sha, check: check, selection: entry)
      end
    end

    def skipped_selection_entries(job)
      job.workflows.order(created_at: :desc, id: :desc).flat_map do |workflow|
        Array(workflow.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY)).map do |entry|
          stringify_hash(entry).merge(
            "selection_workflow_id" => workflow.id,
            "selection_workflow_trigger_kind" => workflow.trigger_kind,
            "selection_workflow_created_at" => workflow.created_at&.iso8601
          )
        end
      end.select do |entry|
        entry["target_label"].present? && entry["affected"] == false
      end
    end

    def missed_edge_for(job:, head_sha:, check:, selection:)
      context = check["target_context"]
      check_name = check["name"].to_s
      target_label = context["target_label"]
      {
        "head_sha" => head_sha,
        "check_name" => check_name,
        "check_conclusion" => check["conclusion"],
        "check_url" => check["html_url"] || check["url"],
        "target_label" => target_label,
        "project_id" => context["project_id"],
        "project_label" => context["project_label"],
        "source_scope" => context["source_scope"],
        "dependencies" => context["dependencies"],
        "selection_reason" => selection["reason"],
        "selection_workflow_id" => selection["selection_workflow_id"],
        "selection_workflow_trigger_kind" => selection["selection_workflow_trigger_kind"],
        "selection_workflow_created_at" => selection["selection_workflow_created_at"],
        "target_fingerprints" => selection["target_fingerprints"],
        "suggested_fixes" => context["suggested_fixes"],
        "dedupe_key" => [ job.id, head_sha, check_name, target_label ].join(":")
      }.compact
    end

    def with_graph(job:, head_sha:, graph:, workspace_path:)
      return yield(graph, workspace_path) if graph && workspace_path

      Dir.mktmpdir("ci-repair-target-context-") do |dir|
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

      stdout, stderr, status = Open3.capture3("tar", "-x", "-C", dir, stdin_data: stdout)
      raise "tar extract failed: #{stderr.presence || status.exitstatus}" unless status.success?
    end

    def stringify_hash(value)
      value = value.to_h if value.respond_to?(:to_h)
      value = {} unless value.is_a?(Hash)
      value.deep_stringify_keys
    end
  end
end
