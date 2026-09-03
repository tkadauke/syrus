module TeamDirectory
  class Engine < ::Rails::Engine
    config.after_initialize do
      TeamDirectory.register!
    end
  end
end
