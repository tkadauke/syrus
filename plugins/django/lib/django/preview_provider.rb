module Django
  # :preview_provider for Django repositories: detects manage.py plus an
  # importable Django settings module (parsed from manage.py's
  # DJANGO_SETTINGS_MODULE assignment, resolved to a real file on disk — no
  # python interpreter needed to answer detect?).
  class PreviewProvider
    SETTINGS_MODULE_PATTERN = /DJANGO_SETTINGS_MODULE["']\s*,\s*["']([\w.]+)["']/

    def detect?(repo_path)
      manage_py = File.join(repo_path, "manage.py")
      return false unless File.exist?(manage_py)

      !settings_module_path(repo_path, manage_py).nil?
    end

    def start_command(port:)
      "python manage.py runserver 0.0.0.0:#{port}"
    end

    def seed_command
      "python manage.py migrate && " \
        "if python manage.py seed --help > /dev/null 2>&1; then python manage.py seed; " \
        "elif [ -f fixtures/seed.json ]; then python manage.py loaddata fixtures/seed.json; fi"
    end

    def setup_commands
      [
        "if [ -f uv.lock ]; then uv sync; elif [ -f poetry.lock ]; then poetry install; " \
          "elif [ -f requirements.txt ]; then pip install -r requirements.txt; " \
          "elif [ -f pyproject.toml ]; then pip install -e .; fi"
      ]
    end

    def health_check_path
      # Django ships no Rails-style built-in `/up`. django.contrib.admin's login
      # view is part of the default `startproject` scaffold and returns 200
      # without requiring authentication, so it doubles as a readiness signal
      # any stock Django project answers.
      "/admin/login/"
    end

    def log_paths
      []
    end

    def env
      {}
    end

    def unset_env
      []
    end

    private

    def settings_module_path(repo_path, manage_py)
      match = File.read(manage_py).match(SETTINGS_MODULE_PATTERN)
      return nil unless match

      relative = match[1].tr(".", "/")
      candidates = [
        File.join(repo_path, "#{relative}.py"),
        File.join(repo_path, relative, "__init__.py")
      ]
      candidates.find { |path| File.exist?(path) }
    end
  end
end
