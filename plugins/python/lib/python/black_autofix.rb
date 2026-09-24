require "shellwords"

module Python
  # :autofix_command for `black`. Gated on a [tool.black] table in
  # pyproject.toml — black has no standalone config file convention.
  class BlackAutofix
    def self.autofix_command(workspace_path:, changed_files:)
      pyproject = Pathname.new(workspace_path).join("pyproject.toml")
      return nil unless pyproject.exist? && pyproject.read.include?("[tool.black")

      files = Array(changed_files).select { |file| file.end_with?(".py", ".pyi") }
      return nil if files.empty?

      "black #{Shellwords.join(files)}"
    end
  end
end
