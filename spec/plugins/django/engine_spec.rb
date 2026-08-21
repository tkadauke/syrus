require "rails_helper"
require "tmpdir"

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
          description: "Django framework intelligence: preview hosting via manage.py " \
                       "runserver, migrate-based seeding with a documented fixtures/seed " \
                       "convention",
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

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Django::VERSION)
      expect(registration.depends_on).to eq([ "python" ])
    end

    it "provides exactly the :preview_provider extension point key" do
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
      around do |ex|
        Dir.mktmpdir("syrus-django-preview-provider") { |dir| @dir = dir; ex.run }
      end

      def write(rel, contents = "")
        path = File.join(@dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def manage_py(settings_module: "mysite.settings", quote: "'")
        <<~PY
          import os
          os.environ.setdefault(#{quote}DJANGO_SETTINGS_MODULE#{quote}, #{quote}#{settings_module}#{quote})
        PY
      end

      it "returns false for an empty directory" do
        expect(provider.detect?(@dir)).to be false
      end

      it "returns false when manage.py exists but the settings module has no file on disk" do
        write("manage.py", manage_py)

        expect(provider.detect?(@dir)).to be false
      end

      it "returns true when manage.py's settings module resolves to a module file" do
        write("manage.py", manage_py)
        write("mysite/settings.py")

        expect(provider.detect?(@dir)).to be true
      end

      it "returns true when the settings module resolves to a package's __init__.py" do
        write("manage.py", manage_py(settings_module: "mysite.settings"))
        write("mysite/settings/__init__.py")

        expect(provider.detect?(@dir)).to be true
      end

      it "resolves nested settings modules (e.g. settings.dev) to the right file" do
        write("manage.py", manage_py(settings_module: "mysite.settings.dev"))
        write("mysite/settings/dev.py")

        expect(provider.detect?(@dir)).to be true
      end

      it "handles double-quoted DJANGO_SETTINGS_MODULE assignments" do
        write("manage.py", manage_py(quote: '"'))
        write("mysite/settings.py")

        expect(provider.detect?(@dir)).to be true
      end

      it "returns false when manage.py has no DJANGO_SETTINGS_MODULE assignment" do
        write("manage.py", "print('hello')\n")

        expect(provider.detect?(@dir)).to be false
      end
    end

    describe "#start_command" do
      it "runs manage.py runserver bound to all interfaces on the given port" do
        expect(provider.start_command(port: 3001)).to eq("python manage.py runserver 0.0.0.0:3001")
      end

      it "interpolates the port" do
        expect(provider.start_command(port: 4567)).to include("0.0.0.0:4567")
      end
    end

    describe "#seed_command" do
      it "migrates, then prefers a custom seed management command, then falls back to a fixture" do
        expect(provider.seed_command).to eq(
          "python manage.py migrate && " \
          "if python manage.py seed --help > /dev/null 2>&1; then python manage.py seed; " \
          "elif [ -f fixtures/seed.json ]; then python manage.py loaddata fixtures/seed.json; fi"
        )
      end
    end

    describe "#setup_commands" do
      it "branches across uv/poetry/pip in the same priority order as the python plugin's prepare_detector" do
        expect(provider.setup_commands).to eq([
          "if [ -f uv.lock ]; then uv sync; elif [ -f poetry.lock ]; then poetry install; " \
            "elif [ -f requirements.txt ]; then pip install -r requirements.txt; " \
            "elif [ -f pyproject.toml ]; then pip install -e .; fi"
        ])
      end
    end

    describe "#health_check_path" do
      it "defaults to the Django admin login view since there is no built-in /up" do
        expect(provider.health_check_path).to eq("/admin/login/")
      end
    end

    describe "#log_paths" do
      it "declares no log paths by default" do
        expect(provider.log_paths).to eq([])
      end
    end

    describe "#env" do
      it "sets no environment variables by default" do
        expect(provider.env).to eq({})
      end
    end

    describe "#unset_env" do
      it "unsets no environment variables by default" do
        expect(provider.unset_env).to eq([])
      end
    end
  end

  # Syrus::Plugin::PreviewProvider.for_repo is the production resolution path
  # (see PreviewCommandSource#from_plugin) — unlike Syrus::PreviewProviderResolver
  # (a legacy helper only exercised against direct-form instance registration
  # in spec/plugins/rails/syrus_rails_preview_provider_spec.rb), it correctly
  # instantiates manifest-form class registrations like the one
  # Django::Engine's after_initialize block performs above.
  describe "Syrus::Plugin::PreviewProvider.for_repo resolution" do
    before { Syrus::PluginRegistry.reset! }
    after  { Syrus::PluginRegistry.reset! }

    def register_django!
      Syrus::PluginRegistry.register(
        name: "django", version: Django::VERSION,
        depends_on: [ "python" ],
        provides: { preview_provider: Django::PreviewProvider }
      )
    end

    it "resolves a Django::PreviewProvider instance for a repo with manage.py and a settings module" do
      register_django!

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "mysite"))
        File.write(File.join(dir, "mysite", "settings.py"), "")
        File.write(File.join(dir, "manage.py"), <<~PY)
          os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'mysite.settings')
        PY

        provider = Syrus::Plugin::PreviewProvider.for_repo(dir)
        expect(provider).to be_a(Django::PreviewProvider)
      end
    end

    it "returns nil for a non-Django directory" do
      register_django!

      Dir.mktmpdir do |dir|
        expect(Syrus::Plugin::PreviewProvider.for_repo(dir)).to be_nil
      end
    end
  end
end
