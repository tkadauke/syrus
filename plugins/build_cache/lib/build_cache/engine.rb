module BuildCache
  class Engine < ::Rails::Engine
    config.to_prepare do
      BuildCache.register!
    end
  end
end
