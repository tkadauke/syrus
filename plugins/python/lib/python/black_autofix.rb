module Python
  # :autofix_command for `black`. Gated on a [tool.black] table in
  # pyproject.toml — black has no standalone config file convention.
  class BlackAutofix
    def self.autofix_command(workspace_path:)
      pyproject = Pathname.new(workspace_path).join("pyproject.toml")
      return nil unless pyproject.exist? && pyproject.read.include?("[tool.black")

      "black ."
    end
  end
end
