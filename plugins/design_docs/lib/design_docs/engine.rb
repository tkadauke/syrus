module DesignDocs
  class Engine < ::Rails::Engine
    config.after_initialize do
      DesignDocs.register!
    end
  end
end
