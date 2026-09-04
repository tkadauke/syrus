require "python/prepare_detector"
require "python/grader_augmentor"
require "python/ruff_format_autofix"
require "python/black_autofix"
require "python/dependency_audit_command"
require "python/prompt_context"
require "python/review_criteria_provider"

module Python
  extend Syrus::PluginApi

  syrus_plugin "python" do
    description "Python-generic intelligence: uv/poetry/pip prepare detection, " \
      "pytest JSON-report grader detail, venv/uv prompt reminder, " \
      "ruff format/black autofix, pip-audit dependency scanning, default type-hint review criterion"
    long_description "Python provides language-level support for Python repositories. It detects common dependency managers, prepares environments with uv, Poetry, or pip, augments pytest grader output, contributes formatter and dependency-audit commands, and reminds agents about virtual environment conventions.\n\nUse it for Python applications, scripts, libraries, and mixed-language repositories with Python components. Framework-specific plugins such as Django can depend on it for shared Python behavior."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/python.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 30
    provides prepare_detector: "Python::PrepareDetector",
             grader_augmentor: "Python::GraderAugmentor",
             prompt_injector: "Python::PromptContext",
             review_criteria_provider: "Python::ReviewCriteriaProvider",
             autofix_command: [ "Python::RuffFormatAutofix", "Python::BlackAutofix" ],
             dependency_audit_command: "Python::DependencyAuditCommand"
  end
end
