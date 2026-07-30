class EpicDependencyGraphRenderer
  Result = Struct.new(
    :node_count,
    :epic_dependency_count,
    :job_blocker_count,
    :nodes,
    :edges,
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

  def render
    nodes = graph_nodes
    edges = graph_edges

    Result.new(
      node_count: nodes.size,
      epic_dependency_count: epic_dependencies.size,
      job_blocker_count: external_blocker_jobs.size,
      nodes: nodes.values.map { |n| n.slice(:id, :kind, :label, :state, :epic_id, :url, :is_focal) },
      edges: edges.map { |e| { from_id: e.from, to_id: e.to } }
    )
  end

  private

  attr_reader :epic

  def graph_nodes
    nodes = {}
    add_epic_node(nodes, epic)

    related_epics.each do |epic_record|
      add_epic_node(nodes, epic_record)
    end

    external_blocker_jobs.each do |job|
      add_job_node(nodes, job)
    end

    nodes
  end

  def graph_edges
    edges = []

    epic_dependencies.each do |dependency|
      from = epic_node_id(dependency.depends_on_epic)
      to = epic_node_id(dependency.epic)
      edges << Edge.new(from: from, to: to)
    end

    external_job_dependencies.each do |dependency|
      edges << Edge.new(
        from: job_node_id(dependency.depends_on_job),
        to: epic_node_id(epic)
      )
    end

    epic_job_dependencies.each do |dependency|
      edges << Edge.new(
        from: job_node_id(dependency.depends_on_job),
        to: epic_node_id(epic)
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
      .where.not(depends_on_epic_id: nil)
      .order(:id)
      .to_a
  end

  def epic_job_dependencies
    @epic_job_dependencies ||= EpicDependency
      .includes(depends_on_job: [ :repository, :epic ])
      .where(epic_id: epic.id)
      .where.not(depends_on_job_id: nil)
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
    @external_blocker_jobs ||= (external_job_dependencies + epic_job_dependencies)
      .filter_map(&:depends_on_job)
      .uniq(&:id)
      .sort_by(&:id)
  end

  def current_job_ids
    @current_job_ids ||= epic.jobs.order(:id).pluck(:id)
  end

  def add_epic_node(nodes, epic_record)
    nodes[epic_node_id(epic_record)] = {
      id: epic_node_id(epic_record),
      label: "#{epic_record.slug} #{epic_record.title}",
      kind: "epic",
      state: epic_record.state,
      epic_id: epic_record.id,
      url: "/epics/#{epic_record.slug}",
      is_focal: epic_record.id == epic.id
    }
  end

  def add_job_node(nodes, job)
    nodes[job_node_id(job)] = {
      id: job_node_id(job),
      label: job_label(job),
      kind: "job",
      state: job.state,
      epic_id: job.epic_id,
      url: "/jobs/#{job.slug}",
      is_focal: false
    }
  end

  def job_label(job)
    source = job.issue_number.present? ? "##{job.issue_number}" : job.slug
    title = job.issue_title.to_s.strip
    base = title.present? ? "#{source} #{title}" : source

    "#{job.epic&.slug || 'No Epic'} / #{base}"
  end

  def job_node_id(job)
    "job_#{job.id}"
  end

  def epic_node_id(epic_record)
    "epic_#{epic_record.id}"
  end

end
