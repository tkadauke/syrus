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

    attr_reader :graph, :workflow

    def as_json
      selected_targets = filtered_targets
      page_targets = selected_targets.slice(offset, limit) || []
      labels = page_targets.map { |target| target.label.to_s }
      page_health_by_label = latest_health_by_label(labels)

      {
        repository: self.class.repository_json(repository),
        source: source_json,
        projects: projects_json,
        targets: page_targets.map { |target| target_json(target, overlays.fetch(target.label.to_s, {}), page_health_by_label[target.label.to_s]) },
        edges: edges_json(labels),
        page: {
          offset: offset,
          limit: limit,
          total: selected_targets.size,
          next_offset: offset + limit < selected_targets.size ? offset + limit : nil
        },
        filter: filter_tree,
        filter_schema: filter_schema,
        health: health_json(page_health_by_label),
        workflow: workflow && self.class.workflow_json(workflow),
        diagnostics: diagnostics&.to_h,
        error: diagnostics&.error
      }
    end

    def latest_health_by_label(labels)
      labels = Array(labels).map(&:to_s)
      return {} if labels.empty?

      TargetHealthRecord.where(repository: repository, target_label: labels)
                        .includes(:workflow)
                        .latest_first
                        .to_a
                        .uniq(&:target_label)
                        .index_by(&:target_label)
    end

    def all_latest_health_by_label
      @all_latest_health_by_label ||= latest_health_by_label(graph.targets.keys.map(&:to_s))
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

    private

    attr_reader :repository, :diagnostics, :params

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
      targets = graph.targets.values
                     .select { |target| project_filter.blank? || target.project_id == project_filter }
                     .select { |target| kind_filter.blank? || target.kind == kind_filter }
                     .select { |target| target_matches_search?(target) }
                     .select { |target| filter_matches?(target) }

      targets = neighborhood_targets(targets) if neighborhood_mode?
      targets.sort_by { |target| target.label.to_s }
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

    def health_json(records_by_label)
      records = records_by_label.values.compact
      {
        scope: "page",
        targets: records_by_label.transform_values { |record| health_json_for(record) },
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

    def selection_entries
      Array(workflow&.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY))
    end

    def health_skip_entries
      Array(workflow&.artifact(Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY))
    end

    def neighborhood_mode?
      params[:mode].to_s == "neighborhood"
    end

    def neighborhood_targets(candidates)
      labels_by_string = candidates.index_by { |target| target.label.to_s }
      roots = neighborhood_roots(labels_by_string)
      return [] if roots.empty?

      included = Set.new
      frontier = roots.select { |label| labels_by_string.key?(label) }
      max_depth = self.class.non_negative_integer(params[:depth], 1).clamp(0, 4)

      (max_depth + 1).times do |depth|
        break if frontier.empty? || included.size >= limit

        next_frontier = Set.new
        frontier.sort.each do |label|
          next if included.include?(label)

          included.add(label)
          break if included.size >= limit

          next if depth >= max_depth

          neighborhood_neighbors(label, labels_by_string).each do |neighbor|
            next unless labels_by_string.key?(neighbor)
            next if included.include?(neighbor)

            next_frontier.add(neighbor)
          end
        end
        frontier = next_frontier.to_a
      end

      included.map { |label| labels_by_string.fetch(label) }
    end

    def neighborhood_roots(labels_by_string)
      explicit_label = params[:focus_label].to_s.presence
      return [ explicit_label ] if explicit_label

      case params[:focus_state].to_s
      when "selected", "skipped", "cached"
        overlay_roots(params[:focus_state].to_s, labels_by_string)
      when "failing"
        failing_roots(labels_by_string)
      else
        labels_by_string.keys.first(1)
      end
    end

    def overlay_roots(state, labels_by_string)
      overlays.filter_map do |label, overlay|
        label if labels_by_string.key?(label) && overlay[:state] == state
      end
    end

    def failing_roots(labels_by_string)
      latest_health_by_label(labels_by_string.keys).filter_map do |label, record|
        label if record&.status == "failed"
      end
    end

    def neighborhood_neighbors(label, labels_by_string)
      dependencies = Array(labels_by_string[label]&.dependencies).map(&:to_s)
      dependents = dependents_by_label.fetch(label, [])
      direction = params[:direction].to_s.presence || "both"

      case direction
      when "dependencies"
        dependencies
      when "dependents"
        dependents
      else
        dependencies + dependents
      end
    end

    def dependents_by_label
      @dependents_by_label ||= begin
        dependents = Hash.new { |hash, key| hash[key] = [] }
        graph.targets.values.each do |target|
          target.dependencies.each do |dependency|
            dependents[dependency.to_s] << target.label.to_s
          end
        end
        dependents
      end
    end

    def offset
      @offset ||= self.class.non_negative_integer(params[:offset], 0)
    end

    def limit
      @limit ||= self.class.positive_integer(params[:limit], DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
    end

    def project_filter = params[:project_id].to_s.presence
    def kind_filter = params[:kind].to_s.presence
    def label_query
      @label_query ||= begin
        value = params[:search].to_s.presence
        value ||= params[:q].to_s.presence unless encoded_filter_tree?
        value
      end
    end

    def target_matches_search?(target)
      return true if label_query.blank?

      searchable_target_values(target).any? { |value| value.include?(label_query) }
    end

    def searchable_target_values(target)
      [
        target.label.to_s,
        target.owner_config_path,
        graph.project(target.project_id)&.path,
        *target.source_scope
      ].compact.map(&:to_s)
    end

    def encoded_filter_tree?
      decoded_filter_tree.present? && params[:q].present?
    end

    def filter_tree
      @filter_tree ||= begin
        Filters::Ast.serialize(Filters::Ast.parse(decoded_filter_tree || {}))
      rescue ArgumentError
        Filters::Ast.serialize(Filters::Ast::EMPTY)
      end
    end

    def decoded_filter_tree
      @decoded_filter_tree ||= Filters::QueryParam.decode(params[:q])
    end

    def filter_schema
      [
        enum_filter_schema("project_id", "Project", projects_filter_values),
        enum_filter_schema("kind", "Kind", target_kind_values),
        string_filter_schema("label", "Label"),
        string_filter_schema("path", "Path"),
        enum_filter_schema("status", "Status", TargetHealthRecord::STATUSES + %w[selected skipped cached]),
        number_filter_schema("job_id", "Job"),
        number_filter_schema("workflow_id", "Workflow")
      ]
    end

    def projects_filter_values
      graph.projects.values.sort_by(&:id).map do |project|
        { "value" => project.id, "label" => project.label.presence || project.id }
      end
    end

    def target_kind_values
      graph.targets.values.map(&:kind).uniq.sort
    end

    def enum_filter_schema(field, label, values)
      {
        "field" => field,
        "label" => label,
        "bucket" => "enum",
        "operators" => %w[is is_not is_one_of is_none_of is_set is_unset],
        "values" => Filters::Schema.humanize_values(values)
      }
    end

    def string_filter_schema(field, label)
      {
        "field" => field,
        "label" => label,
        "bucket" => "string",
        "operators" => %w[contains does_not_contain starts_with does_not_start_with ends_with does_not_end_with equals not_equals is_set is_unset]
      }
    end

    def number_filter_schema(field, label)
      {
        "field" => field,
        "label" => label,
        "bucket" => "number",
        "operators" => %w[equals not_equals greater_than less_than between is_set is_unset]
      }
    end

    def filter_matches?(target)
      TargetFilterEvaluator.new(self, target).matches?(Filters::Ast.parse(filter_tree))
    rescue ArgumentError
      true
    end

    class TargetFilterEvaluator
      def initialize(payload, target)
        @payload = payload
        @target = target
      end

      def matches?(node)
        if node.is_a?(Filters::Ast::AndNode)
          node.children.all? { |child| matches?(child) }
        elsif node.is_a?(Filters::Ast::OrNode)
          node.children.any? { |child| matches?(child) }
        elsif node.is_a?(Filters::Ast::NotNode)
          !matches?(node.child)
        elsif node.is_a?(Filters::Ast::Chip)
          TargetFilterChip.new(payload, target, node).matches?
        else
          true
        end
      end

      private

      attr_reader :payload, :target
    end

    class TargetFilterChip
      def initialize(payload, target, chip)
        @payload = payload
        @target = target
        @chip = chip
      end

      def matches?
        case chip.field
        when "project_id" then enum_match?(target.project_id)
        when "kind" then enum_match?(target.kind)
        when "label" then string_match?(target.label.to_s)
        when "path" then string_match?(path_values)
        when "status" then enum_match?(status_values)
        when "job_id" then number_match?(job_id_value)
        when "workflow_id" then number_match?(workflow_id_value)
        else true
        end
      end

      private

      attr_reader :payload, :target, :chip

      def enum_match?(candidate)
        values = Array(candidate).compact.map(&:to_s)
        expected = Array(chip.value).compact.map(&:to_s)

        case chip.op
        when "is" then values.include?(chip.value.to_s)
        when "is_not" then values.exclude?(chip.value.to_s)
        when "is_one_of" then (values & expected).any?
        when "is_none_of" then (values & expected).empty?
        when "is_set" then values.any?(&:present?)
        when "is_unset" then values.empty? || values.all?(&:blank?)
        else true
        end
      end

      def string_match?(candidate)
        values = Array(candidate).compact.map(&:to_s)
        expected = chip.value.to_s

        case chip.op
        when "contains" then values.any? { |value| value.include?(expected) }
        when "does_not_contain" then values.none? { |value| value.include?(expected) }
        when "starts_with" then values.any? { |value| value.start_with?(expected) }
        when "does_not_start_with" then values.none? { |value| value.start_with?(expected) }
        when "ends_with" then values.any? { |value| value.end_with?(expected) }
        when "does_not_end_with" then values.none? { |value| value.end_with?(expected) }
        when "equals" then values.include?(expected)
        when "not_equals" then values.exclude?(expected)
        when "is_set" then values.any?(&:present?)
        when "is_unset" then values.empty? || values.all?(&:blank?)
        else true
        end
      end

      def number_match?(candidate)
        value = integer_or_nil(candidate)

        case chip.op
        when "equals" then value && value == integer_or_nil(chip.value)
        when "not_equals" then value.nil? || value != integer_or_nil(chip.value)
        when "greater_than" then value && value > integer_or_nil(chip.value).to_i
        when "less_than" then value && value < integer_or_nil(chip.value).to_i
        when "between"
          min, max = Array(chip.value).map { |entry| integer_or_nil(entry) }
          value && (!min || value >= min) && (!max || value <= max)
        when "is_set" then value.present?
        when "is_unset" then value.nil?
        else true
        end
      end

      def path_values
        [
          target.owner_config_path,
          payload.graph.project(target.project_id)&.path,
          *target.source_scope
        ].compact.map(&:to_s)
      end

      def status_values
        [
          payload.overlays.dig(target.label.to_s, :state),
          payload.all_latest_health_by_label[target.label.to_s]&.status
        ].compact
      end

      def job_id_value
        payload.workflow&.job_id || health_workflow&.job_id
      end

      def workflow_id_value
        payload.workflow&.id || payload.all_latest_health_by_label[target.label.to_s]&.workflow_id
      end

      def health_workflow
        payload.all_latest_health_by_label[target.label.to_s]&.workflow
      end

      def integer_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
