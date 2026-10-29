class Coworkers::MemoryBrowser
  ROOT = "memory/".freeze
  CATEGORIES = %w[daily people repos banks].freeze
  MAX_BYTES = 64.kilobytes
  SCHEMA = [
    {
      "field" => "query", "label" => "Search", "bucket" => "string",
      "operators" => %w[contains], "values" => [], "free_text_search" => true
    }
  ].freeze

  def initialize(coworker:, repository:, user:, params:)
    @coworker = coworker
    @content = RepositoryContent.for(repository, user: user)
    @filter = Filters::Ast.parse(Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME]))
    @requested_path = params[:path].to_s.presence
  end

  def call
    revision = @content.resolve("coworkers/#{@coworker.handle}")
    entries = @content.tree(revision, glob: "memory/{daily,people,repos,banks}/**/*.md")
      .select(&:file?)
    files = entries.map { |entry| file_json(revision, entry.path) }
    files.select! { |file| matches?(file) } if query.present?
    files.sort_by! { |file| sort_key(file) }

    {
      files: files,
      selected_path: selected_path(files),
      filter: Filters::Ast.serialize(@filter),
      filter_schema: SCHEMA
    }
  end

  private

  def file_json(revision, path)
    blob = @content.read(revision, path, max_bytes: MAX_BYTES)
    { path: path, category: path.split("/")[1], name: File.basename(path, ".md"), content: blob.text }
  end

  def query
    @query ||= begin
      node = Array(Filters::Ast.serialize(@filter)["and"]).find { |candidate| candidate["field"] == "query" }
      node&.fetch("value", nil).to_s.strip
    end
  end

  def matches?(file)
    file.values_at(:path, :content).any? { |value| value.to_s.downcase.include?(query.downcase) }
  end

  def selected_path(files)
    paths = files.pluck(:path)
    paths.include?(@requested_path) ? @requested_path : paths.first
  end

  def sort_key(file)
    category_index = CATEGORIES.index(file.fetch(:category)) || CATEGORIES.length
    name = file.fetch(:name)
    [ category_index, file.fetch(:category) == "daily" ? name.chars.map { |char| -char.ord } : name.downcase ]
  end
end
