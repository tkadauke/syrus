module BuildCache
  class Engine < ::Rails::Engine
    config.after_initialize do
      BuildCache.register!
    end
  end
end
