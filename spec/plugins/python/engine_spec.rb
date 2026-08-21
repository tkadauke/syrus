require "rails_helper"
require "tmpdir"

RSpec.describe Python::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "python" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("python")
        Syrus::PluginRegistry.register(
          name:             "python",
          version:          Python::VERSION,
          description:      "Python-generic intelligence: uv/poetry/pip prepare detection, " \
                             "pytest JSON-report grader detail, venv/uv prompt reminder, " \
                             "default type-hint review criterion",
          homepage:         "https://github.com/tkadauke/syrus",
          prepare_priority: 30,
          provides: {
            prepare_detector:         Python::PrepareDetector,
            grader_augmentor:         Python::GraderAugmentor,
            prompt_injector:          Python::PromptContext,
            review_criteria_provider: Python::ReviewCriteriaProvider
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
      expect(registration.version).to eq(Python::VERSION)
      expect(registration.prepare_priority).to eq(30)
    end

    it "provides exactly the 4 extension point keys" do
      expect(registration.provides.keys).to contain_exactly(
        :prepare_detector,
        :grader_augmentor,
        :prompt_injector,
        :review_criteria_provider
      )
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(Python::PrepareDetector)
    end

    it "registers GraderAugmentor as the :grader_augmentor" do
      expect(registration.provides[:grader_augmentor]).to eq(Python::GraderAugmentor)
    end

    it "registers PromptContext as the :prompt_injector" do
      expect(registration.provides[:prompt_injector]).to eq(Python::PromptContext)
    end

    it "registers ReviewCriteriaProvider as the :review_criteria_provider" do
      expect(registration.provides[:review_criteria_provider]).to eq(Python::ReviewCriteriaProvider)
    end
  end

  describe Python::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-python-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no recognized signal" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "uv.lock wins over poetry.lock, requirements.txt, and pyproject.toml" do
      write("pyproject.toml")
      write("requirements.txt")
      write("poetry.lock")
      write("uv.lock")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "uv sync" ])
    end

    it "poetry.lock wins over requirements.txt and pyproject.toml" do
      write("pyproject.toml")
      write("requirements.txt")
      write("poetry.lock")

      expect(described_class.prepare_commands(@dir)).to eq([ "poetry install" ])
    end

    it "requirements.txt wins over bare pyproject.toml" do
      write("pyproject.toml")
      write("requirements.txt")

      expect(described_class.prepare_commands(@dir)).to eq([ "pip install -r requirements.txt" ])
    end

    it "bare pyproject.toml → pip install -e ." do
      write("pyproject.toml")

      expect(described_class.prepare_commands(@dir)).to eq([ "pip install -e ." ])
    end

    it "declares .python-version as its mise version file" do
      expect(described_class.mise_version_file).to eq(".python-version")
    end
  end

  describe Python::PromptContext do
    it "returns a venv/uv activation reminder" do
      text = described_class.call(repository: nil, job: nil)

      expect(text).to include("virtual")
      expect(text).to include("uv run")
      expect(text).to include("poetry run")
    end
  end

  describe Python::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-python-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no recognized Python signal" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the type-hint criterion when a Python project is detected" do
      write("pyproject.toml")

      expect(described_class.criteria(@dir)).to eq([ "Flag missing type hints on new public functions" ])
    end
  end
end
