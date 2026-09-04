module GlobalSearch
  class Engine < ::Rails::Engine
    config.after_initialize do
      GlobalSearch.register!
    end
  end
end
