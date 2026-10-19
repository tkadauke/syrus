require "fileutils"
require "json"
require "tempfile"

class PreparedWorkspaceState
  MARKER = ".syrus/prepared-workspace.json".freeze

  def initialize(workspace_path)
    @workspace_path = Pathname.new(workspace_path)
  end

  def commands
    Array(JSON.parse(marker_path.read)["commands"])
  rescue Errno::ENOENT, JSON::ParserError, TypeError
    []
  end

  def record!(commands)
    FileUtils.mkdir_p(marker_path.dirname)
    Tempfile.create([ "prepared-workspace", ".json" ], marker_path.dirname) do |file|
      file.write(JSON.generate(
        "commands" => Array(commands),
        "prepared_at" => Time.current.iso8601
      ))
      file.flush
      file.fsync
      File.rename(file.path, marker_path)
    end
  end

  private

  def marker_path
    @workspace_path.join(MARKER)
  end
end
