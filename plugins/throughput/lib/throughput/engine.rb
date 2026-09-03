module Throughput
  class Engine < ::Rails::Engine
    config.after_initialize do
      Throughput.register!
    end
  end
end
