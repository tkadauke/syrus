require "fileutils"
require "json"
require "tempfile"

class PreparedWorkspaceState
  MARKER = ".syrus/prepared-workspace.json".freeze

  def initialize(workspace_path)
    @workspace_path = Pathname.new(workspace_path)
  end

  def commands
    Array(payload&.fetch("commands", nil))
  end

  def prepared_for?(expected_commands)
    payload.present? && (Array(expected_commands) - commands).empty?
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
    @payload = nil
  end

  private

  def payload
    @payload ||= JSON.parse(marker_path.read)
  rescue Errno::ENOENT, JSON::ParserError, TypeError
    nil
  end

  def marker_path
    @workspace_path.join(MARKER)
  end
end
