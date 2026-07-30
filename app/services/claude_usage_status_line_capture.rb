require "fileutils"
require "json"
require "rbconfig"
require "shellwords"

class ClaudeUsageStatusLineCapture
  SCRIPT_NAME = "claude-usage-status-line.rb"
  SNAPSHOT_NAME = "claude-usage-status-line.json"

  def self.prepare!(workspace_path:)
    new(workspace_path: workspace_path).tap(&:prepare!)
  end

  attr_reader :snapshot_path

  def initialize(workspace_path:)
    @root = Pathname.new(workspace_path).join(".syrus", "claude-usage")
    @script_path = @root.join(SCRIPT_NAME)
    @snapshot_path = @root.join(SNAPSHOT_NAME)
  end

  def prepare!
    FileUtils.mkdir_p(@root)
    write_script
    self
  end

  def settings
    {
      statusLine: {
        type: "command",
        command: "#{RbConfig.ruby.shellescape} #{@script_path.to_s.shellescape} #{@snapshot_path.to_s.shellescape}"
      }
    }
  end

  def read_payload
    return {} unless File.exist?(@snapshot_path)

    JSON.parse(File.read(@snapshot_path))
  rescue JSON::ParserError
    {}
  end

  private

  def write_script
    return if File.exist?(@script_path) && File.read(@script_path) == script_content

    File.write(@script_path, script_content)
    File.chmod(0o700, @script_path)
  end

  def script_content
    <<~RUBY
      #!/usr/bin/env ruby
      require "json"
      require "time"

      begin
        output_path = ARGV.fetch(0)
        payload = JSON.parse(STDIN.read)
        rate_limits = payload["rate_limits"]
        exit 0 unless rate_limits.is_a?(Hash)

        snapshot = {
          "captured_at" => Time.now.utc.iso8601,
          "rate_limits" => rate_limits
        }
        File.write(output_path, JSON.generate(snapshot))
      rescue StandardError
        exit 0
      end
    RUBY
  end
end
