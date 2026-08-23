require "rails_helper"
require_relative "../../../plugins/rails/lib/syrus_rails"

RSpec.describe SyrusRails::PreviewProvider do
  subject(:provider) { described_class.new }

  it "includes Syrus::Plugin::PreviewProvider" do
    expect(provider).to be_a(Syrus::Plugin::PreviewProvider)
  end

  describe "#detect?" do
    it "returns true when all three marker files exist" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        expect(provider.detect?(dir)).to be true
      end
    end

    it "returns false when bin/rails is absent" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))

        expect(provider.detect?(dir)).to be false
      end
    end

    it "returns false when Gemfile is absent" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        expect(provider.detect?(dir)).to be false
      end
    end

    it "returns false when config/application.rb is absent" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

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
    it "returns a command that starts Vite when package.json defines a dev script" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        File.write(File.join(dir, "package.json"), { "scripts" => { "dev" => "vite" } }.to_json)
        provider.detect?(dir)

        expect(provider.start_command(port: 3001))
          .to eq("mkdir -p log tmp/pids && if [ -f package.json ]; then npm run dev > log/vite.log 2>&1 & fi && exec bin/rails server -p 3001 -b 0.0.0.0 -e development")
      end
    end

    it "omits the Vite fragment when package.json has no dev script" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        File.write(File.join(dir, "package.json"), { "scripts" => { "build" => "vite build" } }.to_json)
        provider.detect?(dir)

        expect(provider.start_command(port: 3001))
          .to eq("mkdir -p log tmp/pids && exec bin/rails server -p 3001 -b 0.0.0.0 -e development")
      end
    end

    it "omits the Vite fragment when package.json has no scripts key" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        File.write(File.join(dir, "package.json"), {}.to_json)
        provider.detect?(dir)

        expect(provider.start_command(port: 3001))
          .to eq("mkdir -p log tmp/pids && exec bin/rails server -p 3001 -b 0.0.0.0 -e development")
      end
    end

    it "omits the Vite fragment when package.json is absent" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        provider.detect?(dir)

        expect(provider.start_command(port: 3001))
          .to eq("mkdir -p log tmp/pids && exec bin/rails server -p 3001 -b 0.0.0.0 -e development")
      end
    end

    it "interpolates the port into the command" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        provider.detect?(dir)

        expect(provider.start_command(port: 4567))
          .to include("bin/rails server -p 4567 -b 0.0.0.0 -e development")
      end
    end

    it "falls back to skipping the Vite fragment when called without a prior detect?" do
      expect(provider.start_command(port: 3001))
        .to eq("mkdir -p log tmp/pids && exec bin/rails server -p 3001 -b 0.0.0.0 -e development")
    end
  end

  describe "#seed_command" do
    it "returns the db setup command" do
      expect(provider.seed_command).to eq("bin/rails db:create db:migrate db:seed")
    end
  end

  describe "#setup_commands" do
    it "installs gems into the preview workspace before seed/start" do
      expect(provider.setup_commands).to eq([
        "bundle config set --local path vendor/bundle",
        "bundle install --jobs 4",
        "if [ -f package-lock.json ]; then npm ci; elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; elif [ -f bun.lockb ] || [ -f bun.lock ]; then bun install --frozen-lockfile; fi"
      ])
    end
  end

  describe "#health_check_path" do
    it "returns /up when config/routes.rb maps the Rails health-check route" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            get "up" => "rails/health#show", as: :rails_health_check
          end
        RUBY
        provider.detect?(dir)

        expect(provider.health_check_path).to eq("/up")
      end
    end

    it "falls back to / when config/routes.rb does not map the health-check route" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        File.write(File.join(dir, "config", "routes.rb"), <<~RUBY)
          Rails.application.routes.draw do
            root "home#index"
          end
        RUBY
        provider.detect?(dir)

        expect(provider.health_check_path).to eq("/")
      end
    end

    it "falls back to / when config/routes.rb is missing" do
      Dir.mktmpdir do |dir|
        touch_rails_markers(dir)
        provider.detect?(dir)

        expect(provider.health_check_path).to eq("/")
      end
    end

    it "falls back to / when called without a prior detect?" do
      expect(provider.health_check_path).to eq("/")
    end
  end

  describe "#log_paths" do
    it "returns the development log path" do
      expect(provider.log_paths).to eq(["log/development.log", "log/vite.log"])
    end
  end

  describe "#env" do
    it "runs Rails previews in development with an isolated search database" do
      expect(provider.env).to eq(
        "RAILS_ENV" => "development",
        "SEARCH_DATABASE_PATH" => "storage/preview_search.sqlite3",
        "VITE_RUBY_SKIP_PROXY" => "false"
      )
    end
  end

  describe "#unset_env" do
    it "strips inherited production database settings" do
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

  def touch_rails_markers(dir)
    FileUtils.touch(File.join(dir, "Gemfile"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.touch(File.join(dir, "config", "application.rb"))
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.touch(File.join(dir, "bin", "rails"))
  end
end

RSpec.describe "SyrusRails plugin registration" do
  before { Syrus::PluginRegistry.reset! }
  after  { Syrus::PluginRegistry.reset! }

  describe "SyrusRails.register!" do
    it "registers a SyrusRails::PreviewProvider under :preview_provider" do
      SyrusRails.register!
      providers = Syrus::PluginRegistry.providers_for(:preview_provider)
      expect(providers.first).to be_a(SyrusRails::PreviewProvider)
    end

    it "allows detect? to be called via PluginRegistry.providers_for" do
      SyrusRails.register!

      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        provider = Syrus::PluginRegistry.providers_for(:preview_provider).first
        expect(provider.detect?(dir)).to be true
      end
    end

    it "returns false for a non-Rails directory via the registry" do
      SyrusRails.register!

      Dir.mktmpdir do |dir|
        provider = Syrus::PluginRegistry.providers_for(:preview_provider).first
        expect(provider.detect?(dir)).to be false
      end
    end
  end
end

RSpec.describe Syrus::PreviewProviderResolver do
  before { Syrus::PluginRegistry.reset! }
  after  { Syrus::PluginRegistry.reset! }

  describe ".for" do
    it "returns the matching provider for a Rails repo path" do
      SyrusRails.register!

      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        resolver = described_class.for(dir)
        expect(resolver).to be_a(SyrusRails::PreviewProvider)
      end
    end

    it "returns nil when no provider detects the repo" do
      SyrusRails.register!

      Dir.mktmpdir do |dir|
        expect(described_class.for(dir)).to be_nil
      end
    end

    it "returns nil when no providers are registered" do
      Dir.mktmpdir do |dir|
        expect(described_class.for(dir)).to be_nil
      end
    end
  end
end
