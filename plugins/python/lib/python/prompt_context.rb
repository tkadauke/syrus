module Python
  # Optional light :prompt_injector: reminds the implementing agent that
  # Python repos commonly need an activated virtual environment or a
  # dependency-manager run-prefix before shell commands see the right
  # interpreter/packages. Unconditional, like SyrusRails::PromptContext —
  # the interface only receives repository/job, not a repo_path to detect
  # pyproject.toml against.
  class PromptContext
    PROMPT = <<~TEXT.freeze
      This repository may be a Python project. If it uses a virtual
      environment or a dependency manager, activate/use it explicitly in any
      shell commands you run instead of assuming a global interpreter has the
      right packages installed — e.g. `source .venv/bin/activate`,
      `uv run <command>`, or `poetry run <command>`.
    TEXT

    def self.call(repository:, job:)
      new.call(repository: repository, job: job)
    end

    def call(repository:, job:)
      PROMPT
    end
  end
end
