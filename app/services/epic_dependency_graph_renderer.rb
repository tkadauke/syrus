require "set"

class EpicDependencyGraphRenderer
  SUMMARY_NODE_THRESHOLD = 100

  Result = Struct.new(:definition, :node_count, :raw_node_count, :summarized, :depth, keyword_init: true)

  Edge = Struct.new(:from, :to, :kind, keyword_init: true)

  GraphRecords = Struct.new(:epics, :jobs, :job_dependencies, :epic_dependencies, keyword_init: true)

  def initialize(epic, depth: :adjacent, summary_node_threshold: SUMMARY_NODE_THRESHOLD)
    @epic = epic
    @depth = depth.to_s == "transitive" ? :transitive : :adjacent
    @summary_node_threshold = summary_node_threshold
  end

  def self.render(epic, depth: :adjacent)
    new(epic, depth: depth).render.definition
  end

  def render
    records = graph_records
    raw_nodes = graph_nodes(records)
    summarized = depth == :transitive && raw_nodes.size > summary_node_threshold
    nodes = summarized ? summarized_graph_nodes(records) : raw_nodes
    edges = summarized ? summarized_graph_edges(records, nodes) : graph_edges(records, nodes)

    lines = [ "flowchart LR" ]
    nodes.each_value { |node| lines << "  #{node[:id]}[\"#{escape_label(node[:label])}\"]" }
    edges.each_with_index do |edge, index|
      lines << edge_definition(edge)
      lines << edge_style(edge, index)
    end

    Result.new(
      definition: lines.join("\n"),
      node_count: nodes.size,
      raw_node_count: raw_nodes.size,
      summarized: summarized,
      depth: depth
    )
  end

  private

  attr_reader :epic, :depth, :summary_node_threshold

  def graph_records
    depth == :transitive ? transitive_graph_records : adjacent_graph_records
  end

  def adjacent_graph_records
    GraphRecords.new(
      epics: ([ epic ] + cross_jobs.filter_map(&:epic) + manual_epic_dependencies.flat_map { |dependency| [ dependency.epic, dependency.depends_on_epic ] }).compact.uniq,
      jobs: current_jobs + cross_jobs,
      job_dependencies: job_dependencies,
      epic_dependencies: manual_epic_dependencies
    )
  end

  def transitive_graph_records
    seen_epic_ids = Set[epic.id]
    seen_job_ids = Set.new
    seen_job_dependency_ids = Set.new
    seen_epic_dependency_ids = Set.new
    epic_frontier = Set[epic.id]
    job_frontier = Set.new

    loop do
      progressed = false

      if epic_frontier.any?
        current_epic_frontier = epic_frontier.to_a
        epic_frontier.clear

        jobs = Job.where(epic_id: current_epic_frontier).pluck(:id)
        new_job_ids = jobs - seen_job_ids.to_a
        if new_job_ids.any?
          new_job_ids.each { |id| seen_job_ids.add(id) }
          job_frontier.merge(new_job_ids)
          progressed = true
        end

        dependencies = EpicDependency.where("epic_id IN (:ids) OR depends_on_epic_id IN (:ids)", ids: current_epic_frontier)
        dependencies.find_each do |dependency|
          seen_epic_dependency_ids.add(dependency.id)
          [ dependency.epic_id, dependency.depends_on_epic_id ].each do |epic_id|
            next if seen_epic_ids.include?(epic_id)

            seen_epic_ids.add(epic_id)
            epic_frontier.add(epic_id)
            progressed = true
          end
        end
      end

      if job_frontier.any?
        current_job_frontier = job_frontier.to_a
        job_frontier.clear

        dependencies = JobDependency.resolved.where("job_id IN (:ids) OR depends_on_job_id IN (:ids)", ids: current_job_frontier)
        dependencies.find_each do |dependency|
          seen_job_dependency_ids.add(dependency.id)
          [ dependency.job_id, dependency.depends_on_job_id ].compact.each do |job_id|
            next if seen_job_ids.include?(job_id)

            seen_job_ids.add(job_id)
            job_frontier.add(job_id)
            progressed = true
          end
        end

        epic_ids = Job.where(id: current_job_frontier).where.not(epic_id: nil).pluck(:epic_id)
        epic_ids.each do |epic_id|
          next if seen_epic_ids.include?(epic_id)

          seen_epic_ids.add(epic_id)
          epic_frontier.add(epic_id)
          progressed = true
        end
      end

      break unless progressed
    end

    GraphRecords.new(
      epics: Epic.where(id: seen_epic_ids.to_a).order(:id).to_a,
      jobs: Job.includes(:epic, :repository).where(id: seen_job_ids.to_a).order(:id).to_a,
      job_dependencies: JobDependency.resolved
                                     .includes(job: [ :repository, :epic ], depends_on_job: [ :repository, :epic ])
                                     .where(id: seen_job_dependency_ids.to_a)
                                     .order(:id)
                                     .to_a,
      epic_dependencies: EpicDependency.includes(:epic, :depends_on_epic)
                                       .where(id: seen_epic_dependency_ids.to_a)
                                       .order(:id)
                                       .to_a
    )
  end

  def graph_nodes(records)
    nodes = {}

    records.epics.each { |epic_record| add_epic_node(nodes, epic_record) }
    records.jobs.each { |job| add_job_node(nodes, job, local: job.epic_id == epic.id) }

    nodes
  end

  def graph_edges(records, nodes)
    edges = []

    records.job_dependencies.each do |dependency|
      next unless dependency.depends_on_job

      from = job_node_id(dependency.depends_on_job)
      to = job_node_id(dependency.job)
      next unless nodes.key?(from) && nodes.key?(to)

      edges << Edge.new(
        from: from,
        to: to,
        kind: same_epic_job_dependency?(dependency) ? :same_epic : :cross_epic
      )
    end

    records.epic_dependencies.each do |dependency|
      from = epic_node_id(dependency.depends_on_epic)
      to = epic_node_id(dependency.epic)
      next unless nodes.key?(from) && nodes.key?(to)

      edges << Edge.new(from: from, to: to, kind: dependency.derived? ? :derived_epic : :manual_epic)
    end

    edges.uniq { |edge| [ edge.from, edge.to, edge.kind ] }
  end

  def summarized_graph_nodes(records)
    nodes = {}
    job_counts = records.jobs.group_by(&:epic_id).transform_values(&:size)

    records.epics.each do |epic_record|
      count = job_counts[epic_record.id].to_i
      label = "#{epic_record.display_number} #{epic_record.title}"
      label = "#{label} (#{count} #{'Job'.pluralize(count)})" if count.positive?
      nodes[epic_node_id(epic_record)] = { id: epic_node_id(epic_record), label: label }
    end

    records.jobs.select { |job| job.epic_id.blank? }.each do |job|
      add_job_node(nodes, job, local: false)
    end

    nodes
  end

  def summarized_graph_edges(records, nodes)
    edges = []

    records.job_dependencies.each do |dependency|
      from_epic = dependency.depends_on_job&.epic
      to_epic = dependency.job&.epic
      next if from_epic.blank? || to_epic.blank? || from_epic.id == to_epic.id

      from = epic_node_id(from_epic)
      to = epic_node_id(to_epic)
      next unless nodes.key?(from) && nodes.key?(to)

      edges << Edge.new(from: from, to: to, kind: :cross_epic)
    end

    records.epic_dependencies.each do |dependency|
      from = epic_node_id(dependency.depends_on_epic)
      to = epic_node_id(dependency.epic)
      next unless nodes.key?(from) && nodes.key?(to)

      edges << Edge.new(from: from, to: to, kind: dependency.derived? ? :derived_epic : :manual_epic)
    end

    edges.uniq { |edge| [ edge.from, edge.to, edge.kind ] }
  end

  def current_jobs
    @current_jobs ||= epic.jobs.order(:id).to_a
  end

  def current_job_ids
    @current_job_ids ||= current_jobs.map(&:id)
  end

  def cross_jobs
    @cross_jobs ||= begin
      ids = job_dependencies.flat_map { |dependency| [ dependency.job_id, dependency.depends_on_job_id ] }
                            .compact
                            .uniq - current_job_ids
      Job.includes(:epic, :repository).where(id: ids).where.not(epic_id: nil).order(:id).to_a
    end
  end

  def job_dependencies
    @job_dependencies ||= begin
      if current_job_ids.empty?
        []
      else
        JobDependency
          .resolved
          .includes(job: [ :repository, :epic ], depends_on_job: [ :repository, :epic ])
          .where("job_id IN (:ids) OR depends_on_job_id IN (:ids)", ids: current_job_ids)
          .order(:id)
          .to_a
          .select { |dependency| include_job_dependency?(dependency) }
      end
    end
  end

  def include_job_dependency?(dependency)
    job_id = dependency.job_id
    depends_on_id = dependency.depends_on_job_id
    return true if current_job_ids.include?(job_id) && current_job_ids.include?(depends_on_id)

    current_job_ids.include?(job_id) || current_job_ids.include?(depends_on_id)
  end

  def manual_epic_dependencies
    @manual_epic_dependencies ||= EpicDependency
      .includes(:epic, :depends_on_epic)
      .where(derived: false)
      .where("epic_id = :id OR depends_on_epic_id = :id", id: epic.id)
      .order(:id)
      .to_a
  end

  def same_epic_job_dependency?(dependency)
    dependency.job&.epic_id == epic.id && dependency.depends_on_job&.epic_id == epic.id
  end

  def add_job_node(nodes, job, local:)
    nodes[job_node_id(job)] = {
      id: job_node_id(job),
      label: job_label(job, local: local)
    }
  end

  def add_epic_node(nodes, epic_record)
    return unless epic_record

    nodes[epic_node_id(epic_record)] = {
      id: epic_node_id(epic_record),
      label: "#{epic_record.display_number} #{epic_record.title}"
    }
  end

  def job_label(job, local:)
    source = job.issue_number.present? ? "##{job.issue_number}" : "Job ##{job.id}"
    title = job.issue_title.to_s.strip
    base = title.present? ? "#{source} #{title}" : source
    return base if local

    "#{job.epic&.display_number || 'No Epic'} / #{base}"
  end

  def edge_definition(edge)
    operator = case edge.kind
               when :cross_epic, :derived_epic then "-.->"
               when :manual_epic then "==>"
               else "-->"
               end
    "  #{edge.from} #{operator} #{edge.to}"
  end

  def edge_style(edge, index)
    style = case edge.kind
            when :cross_epic
              "stroke:#7c3aed,stroke-width:2px,stroke-dasharray:5 4"
            when :manual_epic
              "stroke:#111827,stroke-width:4px"
            when :derived_epic
              "stroke:#6b7280,stroke-width:2px,stroke-dasharray:3 3"
            else
              "stroke:#374151,stroke-width:2px"
            end
    "  linkStyle #{index} #{style}"
  end

  def job_node_id(job)
    "job_#{job.id}"
  end

  def epic_node_id(epic_record)
    "epic_#{epic_record.id}"
  end

  def escape_label(label)
    label.to_s.gsub("\\", "\\\\\\").gsub('"', '\"').gsub(/\s+/, " ").strip
  end
end
