module Python
  # :autofix_command for `ruff format`. Gated on a ruff config signal — a
  # standalone .ruff.toml/ruff.toml, or a [tool.ruff] table in
  # pyproject.toml — so a repo that never configured ruff doesn't get its
  # formatting opinions applied.
  class RuffFormatAutofix
    def self.autofix_command(workspace_path:)
      return nil unless configured?(workspace_path)

      "ruff format ."
    end

    def self.configured?(workspace_path)
      path = Pathname.new(workspace_path)
      return true if path.join(".ruff.toml").exist? || path.join("ruff.toml").exist?

      pyproject = path.join("pyproject.toml")
      pyproject.exist? && pyproject.read.include?("[tool.ruff")
    end
    private_class_method :configured?
  end
end
