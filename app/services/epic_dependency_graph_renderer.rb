class EpicDependencyGraphRenderer
  Result = Struct.new(
    :definition,
    :node_count,
    :epic_dependency_count,
    :job_blocker_count,
    keyword_init: true
  ) do
    def external_dependencies?
      epic_dependency_count.to_i.positive? || job_blocker_count.to_i.positive?
    end

    def empty?
      !external_dependencies?
    end
  end

  Edge = Struct.new(:from, :to, keyword_init: true)

  def initialize(epic)
    @epic = epic
  end

  def self.render(epic)
    new(epic).render.definition
  end

  def render
    nodes = graph_nodes
    edges = graph_edges

    lines = [ "flowchart LR" ]
    nodes.each_value do |node|
      lines << "  #{node[:id]}[\"#{escape_label(node[:label])}\"]"
    end
    nodes.each_value do |node|
      lines << "  class #{node[:id]} #{node[:class_name]}"
    end
    lines.concat(class_definitions)
    edges.each do |edge|
      lines << "  #{edge.from} --> #{edge.to}"
    end

    Result.new(
      definition: lines.join("\n"),
      node_count: nodes.size,
      epic_dependency_count: epic_dependencies.size,
      job_blocker_count: external_blocker_jobs.size
    )
  end

  private

  attr_reader :epic

  def graph_nodes
    nodes = {}
    add_epic_node(nodes, epic, class_name: "currentEpic")

    related_epics.each do |epic_record|
      add_epic_node(nodes, epic_record, class_name: "otherEpic")
    end

    external_blocker_jobs.each do |job|
      add_job_node(
        nodes,
        job,
        class_name: job.epic_id.present? ? "epicJobBlocker" : "epiclessJobBlocker"
      )
    end

    nodes
  end

  def graph_edges
    edges = []

    epic_dependencies.each do |dependency|
      from = epic_node_id(dependency.epic)
      to = epic_node_id(dependency.depends_on_epic)
      edges << Edge.new(from: from, to: to)
    end

    external_job_dependencies.each do |dependency|
      edges << Edge.new(
        from: epic_node_id(epic),
        to: job_node_id(dependency.depends_on_job)
      )
    end

    edges.uniq { |edge| [ edge.from, edge.to ] }
  end

  def related_epics
    @related_epics ||= epic_dependencies
      .flat_map { |dependency| [ dependency.epic, dependency.depends_on_epic ] }
      .compact
      .reject { |epic_record| epic_record.id == epic.id }
      .uniq(&:id)
      .sort_by(&:id)
  end

  def epic_dependencies
    @epic_dependencies ||= EpicDependency
      .includes(:epic, :depends_on_epic)
      .where("epic_id = :id OR depends_on_epic_id = :id", id: epic.id)
      .order(:id)
      .to_a
  end

  def external_job_dependencies
    @external_job_dependencies ||= begin
      if current_job_ids.empty?
        []
      else
        JobDependency
          .resolved
          .includes(depends_on_job: [ :repository, :epic ])
          .joins(:job)
          .where(jobs: { epic_id: epic.id })
          .where.not(depends_on_job_id: current_job_ids)
          .order(:id)
          .to_a
      end
    end
  end

  def external_blocker_jobs
    @external_blocker_jobs ||= external_job_dependencies
      .filter_map(&:depends_on_job)
      .uniq(&:id)
      .sort_by(&:id)
  end

  def current_job_ids
    @current_job_ids ||= epic.jobs.order(:id).pluck(:id)
  end

  def add_epic_node(nodes, epic_record, class_name:)
    nodes[epic_node_id(epic_record)] = {
      id: epic_node_id(epic_record),
      label: "#{epic_record.display_number} #{epic_record.title}",
      class_name: class_name
    }
  end

  def add_job_node(nodes, job, class_name:)
    nodes[job_node_id(job)] = {
      id: job_node_id(job),
      label: job_label(job),
      class_name: class_name
    }
  end

  def job_label(job)
    source = job.issue_number.present? ? "##{job.issue_number}" : "Job ##{job.id}"
    title = job.issue_title.to_s.strip
    base = title.present? ? "#{source} #{title}" : source

    "#{job.epic&.display_number || 'No Epic'} / #{base}"
  end

  def class_definitions
    [
      "  classDef currentEpic fill:#111827,color:#ffffff,stroke:#111827,stroke-width:3px",
      "  classDef otherEpic fill:#eef2ff,color:#111827,stroke:#4f46e5,stroke-width:2px",
      "  classDef epicJobBlocker fill:#ffffff,color:#111827,stroke:#374151,stroke-width:2px",
      "  classDef epiclessJobBlocker fill:#ffffff,color:#111827,stroke:#374151,stroke-width:2px,stroke-dasharray:5 4"
    ]
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
