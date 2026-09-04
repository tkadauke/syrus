module Throughput
  class Engine < ::Rails::Engine
    config.to_prepare do
      Throughput.register!
    end
  end
end
