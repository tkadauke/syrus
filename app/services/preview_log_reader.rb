class PreviewLogReader
  DEFAULT_LINES = 120
  MAX_LINES = 1000

  Log = Data.define(:path, :content, :missing, :offset)

  def self.call(preview_environment, lines: DEFAULT_LINES, offsets: {})
    new(preview_environment, lines: lines, offsets: offsets).call
  end

  def initialize(preview_environment, lines:, offsets: {})
    @preview_environment = preview_environment
    @workspace_path = preview_environment.workspace_path
    @lines = [[Integer(lines.to_i), 1].max, MAX_LINES].min
    @offsets = offsets
  end

  def call
    return [] if @workspace_path.blank? || !Dir.exist?(@workspace_path)

    log_paths.filter_map do |path|
      absolute = resolve_path(path)
      next unless absolute

      path_name = display_path(absolute)
      Log.new(path: path_name, content: read_file(absolute, @offsets[path_name]), missing: !File.exist?(absolute), offset: file_size(absolute))
    end
  end

  private

  def log_paths
    source = preview_command_source.resolve
    Array(source&.log_paths).presence || default_log_paths
  end

  def default_log_paths
    %w[log/development.log log/vite.log]
  end

  def resolve_path(path)
    PreviewLogPath.resolve(
      @workspace_path,
      path,
      base_path: preview_workdir,
      allow_missing: true
    )
  end

  def preview_workdir
    return @workspace_path if @preview_environment.project_id.blank?

    project = TargetGraph::Compiler.compile(@workspace_path).project(@preview_environment.project_id)
    return @workspace_path unless project&.path.present?

    File.join(@workspace_path, project.path)
  rescue StandardError
    @workspace_path
  end

  def preview_command_source
    if @preview_environment.project_id.present?
      PreviewCommandSource.new(@workspace_path, project_id: @preview_environment.project_id)
    else
      PreviewCommandSource.new(@workspace_path)
    end
  end

  def display_path(path)
    Pathname.new(path).relative_path_from(Pathname.new(File.realpath(@workspace_path))).to_s
  rescue ArgumentError
    path
  end

  def tail_file(path)
    return "" unless File.exist?(path)

    File.readlines(path, chomp: true).last(@lines).join("\n")
  rescue Errno::ENOENT
    ""
  end

  def read_file(path, offset)
    return tail_file(path) if offset.nil? || !File.exist?(path) || File.size(path) < offset

    content = File.binread(path, File.size(path) - offset, offset).force_encoding(Encoding::UTF_8).scrub
    offset.positive? && content.present? ? "\n#{content.chomp}" : content
  rescue Errno::ENOENT
    ""
  end

  def file_size(path)
    File.exist?(path) ? File.size(path) : 0
  rescue Errno::ENOENT
    0
  end
end
