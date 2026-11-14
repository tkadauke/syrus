class PreviewLogReader
  DEFAULT_LINES = 120
  MAX_LINES = 1000

  # Upper bound for one incremental chunk; a bigger gap falls back to a full tail.
  MAX_INCREMENTAL_BYTES = 256 * 1024

  # `size` is the file's byte size when read (the client's next `since`
  # cursor). `incremental` means `content` is only the bytes appended after the
  # requested offset and should be appended to what the client already has;
  # otherwise `content` is a full tail replacing it.
  Log = Data.define(:path, :content, :missing, :size, :incremental) do
    def initialize(path:, content:, missing:, size: nil, incremental: false) = super
  end

  # since: { "log/development.log" => byte_offset } from a previous response.
  def self.call(preview_environment, lines: DEFAULT_LINES, since: nil)
    new(preview_environment, lines: lines, since: since).call
  end

  def initialize(preview_environment, lines:, since: nil)
    @since = since.is_a?(Hash) ? since.transform_keys(&:to_s) : {}
    @preview_environment = preview_environment
    @workspace_path = preview_environment.workspace_path
    @lines = [[Integer(lines.to_i), 1].max, MAX_LINES].min
  end

  def call
    return [] if @workspace_path.blank? || !Dir.exist?(@workspace_path)

    log_paths.filter_map do |path|
      absolute = resolve_path(path)
      next unless absolute

      read_log(display_path(absolute), absolute)
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

  def read_log(display, absolute)
    return Log.new(path: display, content: "", missing: true, size: 0) unless File.exist?(absolute)

    size = File.size(absolute)
    offset = Integer(@since[display], exception: false)
    if offset && offset >= 0 && offset <= size && size - offset <= MAX_INCREMENTAL_BYTES
      return Log.new(path: display, content: incremental_chunk(absolute, offset, size), missing: false, size: size, incremental: true)
    end

    Log.new(path: display, content: tail_file(absolute), missing: false, size: size)
  rescue Errno::ENOENT
    Log.new(path: display, content: "", missing: true, size: 0)
  end

  # Bytes appended since `offset`, shaped so plain string concatenation onto the
  # previously returned content reproduces the file: full tails carry no
  # trailing newline, so a chunk that begins on a line boundary gets its
  # separator back, and its own trailing newline is dropped.
  def incremental_chunk(path, offset, size)
    return "" if offset == size

    File.open(path, "rb") do |file|
      boundary = offset.zero? ? false : (file.seek(offset - 1) && file.read(1) == "\n")
      file.seek(offset)
      chunk = file.read(size - offset).to_s.force_encoding(Encoding::UTF_8).scrub
      chunk = chunk.delete_suffix("\n")
      boundary ? "\n#{chunk}" : chunk
    end
  end

  def tail_file(path)
    return "" unless File.exist?(path)

    File.readlines(path, chomp: true).last(@lines).join("\n")
  rescue Errno::ENOENT
    ""
  end
end
