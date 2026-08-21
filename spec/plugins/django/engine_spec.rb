require "rails_helper"

RSpec.describe Django::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "django" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("django")
        Syrus::PluginRegistry.register(
          name:        "django",
          version:     Django::VERSION,
          description: "Django framework intelligence: preview hosting via manage.py runserver, " \
                        "migrate + fixtures seeding",
          homepage:    "https://github.com/tkadauke/syrus",
          depends_on:  [ "python" ],
          provides: {
            preview_provider: Django::PreviewProvider
          }
        )
      end
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "declares a dependency on the python plugin" do
      expect(registration.depends_on).to eq([ "python" ])
    end

    it "provides exactly the :preview_provider extension point" do
      expect(registration.provides.keys).to contain_exactly(:preview_provider)
    end

    it "registers PreviewProvider as the :preview_provider" do
      expect(registration.provides[:preview_provider]).to eq(Django::PreviewProvider)
    end
  end

  describe Django::PreviewProvider do
    subject(:provider) { described_class.new }

    it "includes Syrus::Plugin::PreviewProvider" do
      expect(provider).to be_a(Syrus::Plugin::PreviewProvider)
    end

    describe "#detect?" do
      def write(dir, rel, contents = "")
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def manage_py(settings_module)
        <<~PY
          #!/usr/bin/env python
          import os
          import sys

          def main():
              os.environ.setdefault("DJANGO_SETTINGS_MODULE", "#{settings_module}")
              from django.core.management import execute_from_command_line
              execute_from_command_line(sys.argv)

          if __name__ == "__main__":
              main()
        PY
      end

      it "detects a standard Django repo layout (manage.py + package/settings.py)" do
        Dir.mktmpdir do |dir|
          write(dir, "manage.py", manage_py("myproject.settings"))
          write(dir, "myproject/__init__.py")
          write(dir, "myproject/settings.py")

          expect(provider.detect?(dir)).to be true
        end
      end

      it "detects a settings package (myproject/settings/__init__.py)" do
        Dir.mktmpdir do |dir|
          write(dir, "manage.py", manage_py("myproject.settings"))
          write(dir, "myproject/__init__.py")
          write(dir, "myproject/settings/__init__.py")
          write(dir, "myproject/settings/base.py")

          expect(provider.detect?(dir)).to be true
        end
      end

      it "returns false when manage.py is absent" do
        Dir.mktmpdir do |dir|
          write(dir, "myproject/settings.py")

          expect(provider.detect?(dir)).to be false
        end
      end

      it "returns false when manage.py exists but the settings module cannot be resolved" do
        Dir.mktmpdir do |dir|
          write(dir, "manage.py", manage_py("myproject.settings"))
          # No myproject/settings.py on disk.

          expect(provider.detect?(dir)).to be false
        end
      end

      it "returns false when manage.py has no DJANGO_SETTINGS_MODULE default" do
        Dir.mktmpdir do |dir|
          write(dir, "manage.py", "print('not a real manage.py')")

          expect(provider.detect?(dir)).to be false
        end
      end

      it "returns false for an empty directory" do
        Dir.mktmpdir do |dir|
          expect(provider.detect?(dir)).to be false
        end
      end
    end

    describe "#start_command" do
      it "runs manage.py runserver bound to all interfaces, logging to log/django.log" do
        expect(provider.start_command(port: 3001))
          .to eq("mkdir -p log && exec python manage.py runserver 0.0.0.0:3001 > log/django.log 2>&1")
      end

      it "interpolates the port into the command" do
        expect(provider.start_command(port: 4567)).to include("runserver 0.0.0.0:4567")
      end
    end

    describe "#seed_command" do
      it "migrates, and conditionally loads fixtures/seed.json" do
        expect(provider.seed_command).to eq(
          "python manage.py migrate && if [ -f fixtures/seed.json ]; then python manage.py loaddata fixtures/seed.json; fi"
        )
      end
    end

    describe "#setup_commands" do
      it "branches across uv/poetry/pip package managers in priority order" do
        expect(provider.setup_commands).to eq([
          "if [ -f uv.lock ]; then uv sync; elif [ -f poetry.lock ]; then poetry install; elif [ -f requirements.txt ]; then pip install -r requirements.txt; elif [ -f pyproject.toml ]; then pip install -e .; fi"
        ])
      end
    end

    describe "#health_check_path" do
      it "falls back to the site root since Django has no built-in health endpoint" do
        expect(provider.health_check_path).to eq("/")
      end
    end

    describe "#log_paths" do
      it "exposes the redirected runserver log" do
        expect(provider.log_paths).to eq([ "log/django.log" ])
      end
    end

    describe "#env" do
      it "runs the dev server unbuffered so log output streams immediately" do
        expect(provider.env).to eq("PYTHONUNBUFFERED" => "1")
      end
    end

    describe "#unset_env" do
      it "strips Syrus's own production database settings" do
        expect(provider.unset_env).to include(
          "DATABASE_URL",
          "CACHE_DATABASE_URL",
          "QUEUE_DATABASE_URL",
          "CABLE_DATABASE_URL",
          "DB_HOST",
          "SYRUS_DATABASE_PASSWORD",
          "SYRUS_SQLITE"
        )
      end
    end
  end
end
