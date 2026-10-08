module CodeFacts
  class Classifier
    LANGUAGE_BY_EXTENSION = {
      ".rb" => "Ruby",
      ".rake" => "Ruby",
      ".js" => "JavaScript",
      ".jsx" => "JavaScript",
      ".ts" => "TypeScript",
      ".tsx" => "TypeScript",
      ".go" => "Go",
      ".py" => "Python",
      ".java" => "Java",
      ".kt" => "Kotlin",
      ".kts" => "Kotlin",
      ".rs" => "Rust",
      ".php" => "PHP",
      ".cs" => "C#",
      ".c" => "C",
      ".h" => "C/C++",
      ".cc" => "C++",
      ".cpp" => "C++",
      ".hpp" => "C++",
      ".swift" => "Swift",
      ".sh" => "Shell",
      ".bash" => "Shell",
      ".zsh" => "Shell",
      ".sql" => "SQL",
      ".html" => "HTML",
      ".css" => "CSS",
      ".scss" => "SCSS",
      ".json" => "JSON",
      ".yml" => "YAML",
      ".yaml" => "YAML",
      ".xml" => "XML",
      ".md" => "Markdown"
    }.freeze

    TEST_PATH_PATTERN = %r{(^|/)(spec|test|tests|__tests__)/|(_spec|_test|\.test|\.spec)\.}.freeze
    DOC_EXTENSIONS = %w[.md .markdown .txt .rst .adoc].freeze
    ASSET_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp .ico .pdf .svg .woff .woff2 .ttf .otf].freeze

    def self.language_for(path)
      basename = File.basename(path)
      return "Ruby" if basename == "Gemfile" || basename.end_with?(".gemspec")
      return "Shell" if basename == "Dockerfile"

      LANGUAGE_BY_EXTENSION.fetch(File.extname(path), "Unknown")
    end

    def self.type_for(path)
      extension = File.extname(path)
      return "test" if path.match?(TEST_PATH_PATTERN)
      return "documentation" if DOC_EXTENSIONS.include?(extension)
      return "asset" if ASSET_EXTENSIONS.include?(extension)
      return "configuration" if configuration?(path, extension)
      return "unknown" if language_for(path) == "Unknown"

      "code"
    end

    def self.configuration?(path, extension)
      basename = File.basename(path)
      extension.in?(%w[.json .yml .yaml .toml .ini .env]) ||
        basename.start_with?(".") ||
        basename.in?(%w[Gemfile Dockerfile Makefile Rakefile package-lock.json])
    end
  end
end
