module AdminMysql
  class Engine < ::Rails::Engine
    config.to_prepare do
      AdminMysql.register!
    end
  end
end
