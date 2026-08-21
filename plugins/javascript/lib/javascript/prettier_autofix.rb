module JavaScript
  # :autofix_command for Prettier. Gated on a Prettier config signal —
  # running `prettier --write` with no config at all would impose its
  # opinionated defaults on a repo that never opted in.
  class PrettierAutofix
    CONFIG_FILES = %w[
      .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml
      .prettierrc.js .prettierrc.cjs .prettierrc.mjs
      prettier.config.js prettier.config.cjs prettier.config.mjs
    ].freeze

    def self.autofix_command(workspace_path:)
      return nil unless configured?(workspace_path)

      "npx prettier --write ."
    end

    def self.configured?(workspace_path)
      path = Pathname.new(workspace_path)
      return true if CONFIG_FILES.any? { |file| path.join(file).exist? }

      package_json_declares_prettier?(path)
    end
    private_class_method :configured?

    def self.package_json_declares_prettier?(path)
      package_json = path.join("package.json")
      return false unless package_json.exist?

      JSON.parse(package_json.read).key?("prettier")
    rescue JSON::ParserError
      false
    end
    private_class_method :package_json_declares_prettier?
  end
end
