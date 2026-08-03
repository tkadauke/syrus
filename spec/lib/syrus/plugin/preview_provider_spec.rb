require "rails_helper"
require "syrus/plugin/preview_provider"

RSpec.describe Syrus::Plugin::PreviewProvider do
  def with_clean_registry
    original = described_class.registry.dup
    described_class.instance_variable_set(:@registry, [])
    yield
  ensure
    described_class.instance_variable_set(:@registry, original)
  end

  describe ".register / .registry" do
    it "adds providers to the registry" do
      with_clean_registry do
        provider = Object.new
        described_class.register(provider)
        expect(described_class.registry).to include(provider)
      end
    end

    it "starts empty" do
      with_clean_registry do
        expect(described_class.registry).to be_empty
      end
    end
  end

  describe ".for_repo" do
    it "calls detect? on providers in registration order and returns the first match" do
      with_clean_registry do
        first  = instance_double("FirstProvider",  detect?: false, start_command: nil)
        second = instance_double("SecondProvider", detect?: true,  start_command: nil)
        third  = instance_double("ThirdProvider",  detect?: true,  start_command: nil)

        described_class.register(first)
        described_class.register(second)
        described_class.register(third)

        result = described_class.for_repo("/some/path")

        expect(result).to eq(second)
        expect(third).not_to have_received(:detect?)
      end
    end

    it "returns nil when no provider matches" do
      with_clean_registry do
        provider = instance_double("NoMatchProvider", detect?: false)
        described_class.register(provider)

        expect(described_class.for_repo("/some/path")).to be_nil
      end
    end

    it "returns nil when registry is empty" do
      with_clean_registry do
        expect(described_class.for_repo("/some/path")).to be_nil
      end
    end
  end

  describe "interface defaults" do
    let(:concrete) do
      Class.new do
        include Syrus::Plugin::PreviewProvider

        def detect?(_repo_path) = true
        def start_command(port:) = "bin/server -p #{port}"
      end.new
    end

    it "defaults seed_command to nil" do
      expect(concrete.seed_command).to be_nil
    end

    it "defaults health_check_path to /" do
      expect(concrete.health_check_path).to eq("/")
    end

    it "defaults log_paths to empty array" do
      expect(concrete.log_paths).to eq([])
    end
  end
end
