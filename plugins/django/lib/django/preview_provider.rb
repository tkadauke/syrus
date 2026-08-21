module Django
  class PreviewProvider
    # Syrus's own convention (Django has no bundled seed mechanism): if the
    # repo provides fixtures/seed.json, load it via `manage.py loaddata`
    # after migrating. Documented in plugins/django/README.md.
    SEED_FIXTURE_PATH = "fixtures/seed.json"

    def detect?(repo_path)
      path = Pathname.new(repo_path)
      manage_py = path.join("manage.py")

      manage_py.exist? && settings_module_present?(path, manage_py)
    end

    def start_command(port:)
      "mkdir -p log && exec python manage.py runserver 0.0.0.0:#{port} > log/django.log 2>&1"
    end

    def seed_command
      "python manage.py migrate && if [ -f #{SEED_FIXTURE_PATH} ]; then python manage.py loaddata #{SEED_FIXTURE_PATH}; fi"
    end

    def setup_commands
      [
        "if [ -f uv.lock ]; then uv sync; elif [ -f poetry.lock ]; then poetry install; elif [ -f requirements.txt ]; then pip install -r requirements.txt; elif [ -f pyproject.toml ]; then pip install -e .; fi"
      ]
    end

    # Django has no Rails-style built-in health endpoint. "/" is a
    # best-effort fallback that only succeeds if the app maps a root URL
    # returning 2xx/3xx. Repos without one should set `preview.health_check`
    # in .syrus.yml, which takes priority over this plugin default
    # (PreviewCommandSource#from_syrus_yml).
    def health_check_path
      "/"
    end

    def log_paths
      ["log/django.log"]
    end

    def env
      { "PYTHONUNBUFFERED" => "1" }
    end

    def unset_env
      %w[
        DATABASE_URL
        CACHE_DATABASE_URL
        QUEUE_DATABASE_URL
        CABLE_DATABASE_URL
        DB_HOST
        SYRUS_DATABASE_PASSWORD
        SYRUS_SQLITE
      ]
    end

    private

    def settings_module_present?(path, manage_py)
      module_name = settings_module_name(manage_py)
      return false unless module_name

      relative = module_name.split(".").join("/")
      path.join("#{relative}.py").exist? || path.join(relative, "__init__.py").exist?
    end

    def settings_module_name(manage_py)
      match = manage_py.read.match(/DJANGO_SETTINGS_MODULE["']?\s*,\s*["']([\w.]+)["']/)
      match && match[1]
    end
  end
end
