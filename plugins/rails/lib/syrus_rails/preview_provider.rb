module SyrusRails
  class PreviewProvider
    include Syrus::Plugin::PreviewProvider

    def detect?(repo_path)
      File.exist?(File.join(repo_path, "Gemfile")) &&
        File.exist?(File.join(repo_path, "config", "application.rb")) &&
        File.exist?(File.join(repo_path, "bin", "rails"))
    end

    def start_command(port:)
      "bin/rails server -p #{port} -b 0.0.0.0 -e development"
    end

    def seed_command
      "bin/rails db:create db:migrate db:seed"
    end

    def health_check_path
      "/up"
    end

    def log_paths
      ["log/development.log"]
    end
  end
end
