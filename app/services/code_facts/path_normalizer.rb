module CodeFacts
  module PathNormalizer
    module_function

    def normalize(path, workspace_path: nil, base_path: nil)
      normalized = path.to_s.tr("\\", "/").strip
      workspace_relative = workspace_relative?(normalized, workspace_path)
      normalized = strip_workspace_prefix(normalized, workspace_path)
      normalized = normalized.delete_prefix("./").delete_prefix("/")
      normalized = Pathname.new(normalized).cleanpath.to_s
      normalized = "" if normalized == "."

      scoped_base = normalize_base_path(base_path)
      return normalized if scoped_base.blank?
      return normalized if workspace_relative
      return normalized if normalized == scoped_base || normalized.start_with?("#{scoped_base}/")

      "#{scoped_base}/#{normalized}"
    end

    def strip_workspace_prefix(path, workspace_path)
      return path if workspace_path.blank?

      prefix = Pathname.new(workspace_path.to_s).cleanpath.to_s.tr("\\", "/")
      return path.delete_prefix("#{prefix}/") if path.start_with?("#{prefix}/")

      path
    end

    def workspace_relative?(path, workspace_path)
      return false if workspace_path.blank?

      prefix = Pathname.new(workspace_path.to_s).cleanpath.to_s.tr("\\", "/")
      path.start_with?("#{prefix}/")
    end

    def normalize_base_path(base_path)
      base_path.to_s.tr("\\", "/").strip.delete_prefix("./").delete_prefix("/").presence
    end
  end
end
