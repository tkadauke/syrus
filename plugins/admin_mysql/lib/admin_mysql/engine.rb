module AdminMysql
  class Engine < ::Rails::Engine
    config.after_initialize do
      AdminMysql.register!
    end
  end
end
