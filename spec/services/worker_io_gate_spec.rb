require "rails_helper"

RSpec.describe WorkerIoGate do
  it "serializes archive IO within a worker data root" do
    active = 0
    maximum = 0
    mutex = Mutex.new

    Dir.mktmpdir do |root|
      stub_const("ENV", ENV.to_h.merge("SYRUS_DATA_ROOT" => root))
      threads = 2.times.map do
        Thread.new do
          described_class.synchronize do
            mutex.synchronize do
              active += 1
              maximum = [ maximum, active ].max
            end
            sleep 0.05
            mutex.synchronize { active -= 1 }
          end
        end
      end
      threads.each(&:join)
    end

    expect(maximum).to eq(1)
  end
end
