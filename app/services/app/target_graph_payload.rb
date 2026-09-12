require "set"

module App
  class TargetGraphPayload
    DEFAULT_LIMIT = 500
    MAX_LIMIT = 2_000

    def self.for_repository(repository:, user:, params:)
      App::TargetGraphCheckout.with_default_branch(repository: repository, user: user) do |path|
        new(
          repository: repository,
          graph: TargetGraph::Compiler.compile(path),
          diagnostics: TargetGraph::Compiler.diagnose(path),
          params: params
        ).as_json
      end
    rescue StandardError => e
      error_payload(repository: repository, params: params, source: { scope: "repository", ref: repository.default_branch }, error: e)
    end

    def self.for_workflow(workflow:, params:)
      graph, diagnostics = graph_for_workflow(workflow)
      new(
        repository: workflow.job.repository,
        graph: graph,
        diagnostics: diagnostics,
        workflow: workflow,
        params: params
      ).as_json
    rescue StandardError => e
      error_payload(repository: workflow.job.repository, params: params, source: workflow_source_json(workflow), workflow: workflow, error: e)
    end

    def self.graph_for_workflow(workflow)
      path = WorkflowWorkspace.path_for(workflow)
      if path.join(".git").directory?
        [ TargetGraph::Compiler.compile(path), TargetGraph::Compiler.diagnose(path) ]
      else
        App::TargetGraphCheckout.with_default_branch(repository: workflow.job.repository, user: workflow.user) do |checkout|
          [ TargetGraph::Compiler.compile(checkout), TargetGraph::Compiler.diagnose(checkout) ]
        end
      end
    end

    def self.error_payload(repository:, params:, source:, error:, workflow: nil)
      {
        repository: repository_json(repository),
        source: source,
        projects: [],
        targets: [],
        edges: [],
        page: page_json(params, 0),
        health: { targets: {}, summary: empty_health_summary },
        workflow: workflow && workflow_json(workflow),
        diagnostics: nil,
        error: error.message
      }
    end

    def self.repository_json(repository)
      {
        id: repository.id,
        slug: repository.slug,
        default_branch: repository.default_branch
      }
    end

    def self.workflow_json(workflow)
      {
        id: workflow.id,
        slug: workflow.slug,
        job_id: workflow.job_id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state
      }
    end

    def self.workflow_source_json(workflow)
      {
        scope: "workflow",
        workflow_id: workflow.id,
        ref: workflow.job.branch_name || workflow.job.repository.default_branch
      }
    end

    def self.page_json(params, total_count)
      offset = non_negative_integer(params[:offset], 0)
      limit = positive_integer(params[:limit], DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
      {
        offset: offset,
        limit: limit,
        total: total_count,
        next_offset: offset + limit < total_count ? offset + limit : nil
      }
    end

    def self.empty_health_summary
      TargetHealthRecord::STATUSES.index_with { 0 }
    end

    def self.non_negative_integer(value, default)
      [ Integer(value), 0 ].max
    rescue ArgumentError, TypeError
      default
    end

    def self.positive_integer(value, default)
      parsed = Integer(value)
      parsed.positive? ? parsed : default
    rescue ArgumentError, TypeError
      default
    end

    def initialize(repository:, graph:, diagnostics:, params:, workflow: nil)
      @repository = repository
      @graph = graph
      @diagnostics = diagnostics
      @params = params
      @workflow = workflow
    end

    def as_json
      selected_targets = filtered_targets
      page_targets = selected_targets.slice(offset, limit) || []
      labels = page_targets.map { |target| target.label.to_s }

      {
        repository: self.class.repository_json(repository),
        source: source_json,
        projects: projects_json,
        targets: page_targets.map { |target| target_json(target, overlays.fetch(target.label.to_s, {}), latest_health_by_label[target.label.to_s]) },
        edges: edges_json(labels),
        page: {
          offset: offset,
          limit: limit,
          total: selected_targets.size,
          next_offset: offset + limit < selected_targets.size ? offset + limit : nil
        },
        health: health_json,
        workflow: workflow && self.class.workflow_json(workflow),
        diagnostics: diagnostics&.to_h,
        error: diagnostics&.error
      }
    end

    private

    attr_reader :repository, :graph, :diagnostics, :params, :workflow

    def source_json
      workflow ? self.class.workflow_source_json(workflow) : { scope: "repository", ref: repository.default_branch }
    end

    def projects_json
      graph.projects.values.sort_by(&:id).map do |project|
        {
          id: project.id,
          label: project.label,
          kind: project.kind,
          path: project.path,
          owner_config_path: project.owner_config_path,
          preview: project.preview,
          visual_review: project.visual_review,
          adversarial_review: project.adversarial_review,
          coverage: project.coverage,
          target_count: graph.targets_for_project(project.id).size
        }.compact
      end
    end

    def filtered_targets
      graph.targets.values
           .select { |target| project_filter.blank? || target.project_id == project_filter }
           .select { |target| kind_filter.blank? || target.kind == kind_filter }
           .select { |target| label_query.blank? || target.label.to_s.include?(label_query) }
           .sort_by { |target| target.label.to_s }
    end

    def target_json(target, overlay, health)
      {
        label: target.label.to_s,
        kind: target.kind,
        project_id: target.project_id,
        source_scope: target.source_scope,
        dependencies: target.dependencies.map(&:to_s),
        executable: target.executable?,
        executable_metadata: {
          command: target.command,
          phases: target.phases,
          required: target.required,
          timeout_minutes: target.timeout_minutes,
          metadata: target.metadata
        }.compact,
        owner_config_path: target.owner_config_path,
        selection: overlay.presence,
        health: health_json_for(health)
      }.compact
    end

    def edges_json(labels)
      label_set = labels.to_set
      labels.flat_map do |label|
        graph.target(label).dependencies.map do |dependency|
          {
            from: dependency.to_s,
            to: label,
            kind: "dependency",
            in_window: label_set.include?(dependency.to_s)
          }
        end
      end
    end

    def health_json
      records = latest_health_by_label.values.compact
      {
        targets: latest_health_by_label.transform_values { |record| health_json_for(record) },
        summary: TargetHealthRecord::STATUSES.index_with { |status| records.count { |record| record.status == status } }
      }
    end

    def health_json_for(record)
      return nil unless record

      {
        status: record.status,
        project_id: record.project_id,
        commit_sha: record.commit_sha,
        checked_at: record.checked_at&.iso8601,
        workflow_id: record.workflow_id,
        step_id: record.step_id,
        run_id: record.run_id,
        duration_s: record.duration_s,
        exit_code: record.exit_code,
        log_path: record.log_path,
        log_bytes: record.log_bytes,
        artifacts: record.artifacts.presence,
        metadata: record.metadata.presence
      }.compact
    end

    def latest_health_by_label
      @latest_health_by_label ||= begin
        TargetHealthRecord.where(repository: repository, target_label: graph.targets.keys)
                          .latest_first
                          .to_a
                          .uniq(&:target_label)
                          .index_by(&:target_label)
      end
    end

    def overlays
      @overlays ||= begin
        entries = {}
        selection_entries.each do |entry|
          label = entry["target_label"].to_s
          entries[label] = entries.fetch(label, {}).merge(
            state: entry["affected"] ? "selected" : "skipped",
            reason: entry["reason"],
            name: entry["name"],
            required: entry["required"],
            target_fingerprints: entry["target_fingerprints"]
          ).compact
        end

        health_skip_entries.each do |entry|
          label = entry["target_label"].to_s
          entries[label] = entries.fetch(label, {}).merge(
            state: "cached",
            reason: entry["reason"],
            name: entry["name"],
            required: entry["required"],
            target_health_record_id: entry["target_health_record_id"],
            commit_sha: entry["commit_sha"],
            checked_at: entry["checked_at"],
            target_health_record_refs: entry["target_health_record_refs"]
          ).compact
        end

        entries
      end
    end

    def selection_entries
      Array(workflow&.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY))
    end

    def health_skip_entries
      Array(workflow&.artifact(Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY))
    end

    def offset
      @offset ||= self.class.non_negative_integer(params[:offset], 0)
    end

    def limit
      @limit ||= self.class.positive_integer(params[:limit], DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
    end

    def project_filter = params[:project_id].to_s.presence
    def kind_filter = params[:kind].to_s.presence
    def label_query = params[:q].to_s.presence
  end
end
