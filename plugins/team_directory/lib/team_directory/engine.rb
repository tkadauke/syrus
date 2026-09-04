module TeamDirectory
  class Engine < ::Rails::Engine
    config.to_prepare do
      TeamDirectory.register!
    end
  end
end
