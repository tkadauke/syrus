class EpicDependencyGraphRenderer
  Result = Struct.new(:definition, :node_count, keyword_init: true)

  Edge = Struct.new(:from, :to, :kind, keyword_init: true)

  def initialize(epic)
    @epic = epic
  end

  def self.render(epic)
    new(epic).render.definition
  end

  def render
    nodes = graph_nodes
    edges = graph_edges(nodes)

    lines = [ "flowchart LR" ]
    nodes.each_value { |node| lines << "  #{node[:id]}[\"#{escape_label(node[:label])}\"]" }
    edges.each_with_index do |edge, index|
      lines << edge_definition(edge)
      lines << edge_style(edge, index)
    end

    Result.new(definition: lines.join("\n"), node_count: nodes.size)
  end

  private

  attr_reader :epic

  def graph_nodes
    nodes = {}

    add_epic_node(nodes, epic)
    current_jobs.each { |job| add_job_node(nodes, job, local: true) }
    cross_jobs.each do |job|
      add_epic_node(nodes, job.epic) if job.epic
      add_job_node(nodes, job, local: false)
    end
    manual_epic_dependencies.each do |dependency|
      add_epic_node(nodes, dependency.epic)
      add_epic_node(nodes, dependency.depends_on_epic)
    end

    nodes
  end

  def graph_edges(nodes)
    edges = []

    job_dependencies.each do |dependency|
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

    manual_epic_dependencies.each do |dependency|
      from = epic_node_id(dependency.depends_on_epic)
      to = epic_node_id(dependency.epic)
      next unless nodes.key?(from) && nodes.key?(to)

      edges << Edge.new(from: from, to: to, kind: :manual_epic)
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
               when :cross_epic then "-.->"
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
