class PreviewLogReader
  DEFAULT_LINES = 120
  MAX_LINES = 1000

  Log = Data.define(:path, :content, :missing)

  def self.call(preview_environment, lines: DEFAULT_LINES)
    new(preview_environment, lines: lines).call
  end

  def initialize(preview_environment, lines:)
    @preview_environment = preview_environment
    @workspace_path = preview_environment.workspace_path
    @lines = [[Integer(lines.to_i), 1].max, MAX_LINES].min
  end

  def call
    return [] if @workspace_path.blank? || !Dir.exist?(@workspace_path)

    log_paths.filter_map do |path|
      absolute = resolve_path(path)
      next unless absolute

      Log.new(path: display_path(absolute), content: tail_file(absolute), missing: !File.exist?(absolute))
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
    absolute = Pathname.new(path).absolute? ? File.expand_path(path) : File.expand_path(path, preview_workdir)
    root = File.expand_path(@workspace_path)
    return unless absolute == root || absolute.start_with?("#{root}/")

    absolute
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
    path.delete_prefix("#{File.expand_path(@workspace_path)}/")
  end

  def tail_file(path)
    return "" unless File.exist?(path)

    File.readlines(path, chomp: true).last(@lines).join("\n")
  rescue Errno::ENOENT
    ""
  end
end
