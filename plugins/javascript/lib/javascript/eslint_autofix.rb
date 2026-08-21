module JavaScript
  # :autofix_command for ESLint's --fix. Gated on the same config-file
  # signals ESLint itself looks for (flat config or legacy .eslintrc*), so a
  # repo with no ESLint setup never has `npx eslint --fix .` sprung on it.
  class EslintAutofix
    CONFIG_FILES = %w[
      eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts
      .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml .eslintrc
    ].freeze

    def self.autofix_command(workspace_path:)
      return nil unless configured?(workspace_path)

      "npx eslint --fix ."
    end

    def self.configured?(workspace_path)
      path = Pathname.new(workspace_path)
      CONFIG_FILES.any? { |file| path.join(file).exist? }
    end
    private_class_method :configured?
  end
end
