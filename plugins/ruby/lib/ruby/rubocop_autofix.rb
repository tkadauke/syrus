module Ruby
  # :autofix_command for RuboCop's built-in autocorrect. Only offers the
  # command when a .rubocop.yml is present — running `rubocop -a` on a repo
  # with no rubocop config at all would apply RuboCop's default cop set
  # instead of the repo's own conventions.
  class RubocopAutofix
    def self.autofix_command(workspace_path:)
      return nil unless Pathname.new(workspace_path).join(".rubocop.yml").exist?

      "bundle exec rubocop -a"
    end
  end
end
