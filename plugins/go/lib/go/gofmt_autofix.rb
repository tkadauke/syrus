require "shellwords"

module Go
  # :autofix_command for gofmt. Near-universal and low-risk for any Go
  # module — gofmt has no configuration surface to gate on the way
  # rubocop/eslint/ruff do, so this only checks for go.mod, the same signal
  # Go::PrepareDetector uses.
  class GofmtAutofix
    def self.autofix_command(workspace_path:, changed_files:)
      return nil unless Go::PrepareDetector.detect?(workspace_path)

      files = Array(changed_files).select { |file| file.end_with?(".go") }
      return nil if files.empty?

      "gofmt -w #{Shellwords.join(files)}"
    end
  end
end
