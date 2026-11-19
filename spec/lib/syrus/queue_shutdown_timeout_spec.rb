require "rails_helper"

# SolidQueue's five-second default meant a pod restart killed every running
# job whatever termination grace Kubernetes allowed; a draining compute pod
# raises it through the environment.
RSpec.describe Syrus::QueueShutdownTimeout do
  it "reads whole seconds from SOLID_QUEUE_SHUTDOWN_TIMEOUT" do
    expect(described_class.from_env("SOLID_QUEUE_SHUTDOWN_TIMEOUT" => "3540")).to eq(3540.seconds)
  end

  it "leaves SolidQueue's default alone when unset or invalid" do
    [ {}, { "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => "" }, { "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => "soon" },
      { "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => "0" }, { "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => "-5" } ].each do |env|
      expect(described_class.from_env(env)).to be_nil, env.inspect
    end
  end
end
