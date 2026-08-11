require "rails_helper"
require "syrus/plugin/platform_delivery"

RSpec.describe Syrus::Plugin::PlatformDelivery do
  describe "interface defaults" do
    let(:concrete_class) do
      Class.new do
        include Syrus::Plugin::PlatformDelivery

        def self.platform_key = "discord"
      end
    end

    it "defaults connector_job_class to nil" do
      expect(concrete_class.connector_job_class).to be_nil
    end

    it "raises NotImplementedError when #deliver is not overridden" do
      instance = concrete_class.allocate
      expect {
        instance.deliver(message: nil, platform_identity: nil)
      }.to raise_error(NotImplementedError)
    end
  end

  describe ".platform_key" do
    it "raises NotImplementedError when not overridden" do
      klass = Class.new { include Syrus::Plugin::PlatformDelivery }
      expect { klass.platform_key }.to raise_error(NotImplementedError)
    end
  end

  it "extends including classes with class methods, not instances" do
    klass = Class.new do
      include Syrus::Plugin::PlatformDelivery
      def self.platform_key = "discord"
      def self.connector_job_class = String
    end

    expect(klass.platform_key).to eq("discord")
    expect(klass.connector_job_class).to eq(String)
  end
end
