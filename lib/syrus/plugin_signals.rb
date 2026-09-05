module Syrus
  # The cheap facts a recommendation is allowed to ask about.
  #
  # Recommendations are evaluated for plugins that are *disabled and may never
  # have been enabled*, so they run in the one place where none of the plugin's
  # own code is loaded. A signal block therefore cannot go looking through the
  # plugin's models; it gets this object, and this object answers from core
  # tables only.
  #
  # Everything here is memoized for the life of one evaluation and deliberately
  # coarse. A nudge that costs a table scan every time an admin opens a page is
  # a nudge that gets deleted.
  class PluginSignals
    # Long enough to survive a quiet weekend, short enough that a signal which
    # has genuinely gone away stops being cited.
    RECENT_WINDOW = 30.days

    # Repositories whose last observed file layout matched `plugin_name`.
    #
    # Observations come from `Steps::Prepare`, which already runs the
    # detectors against a fresh clone on every Run. They are a lagging
    # indicator by construction -- a repo Syrus has never run on has no
    # observation -- which is the right failure direction for a suggestion:
    # silence rather than a guess.
    def repositories_detecting(plugin_name)
      detections.fetch(plugin_name.to_s, [])
    end

    # Distinct worker hosts seen recently. One host is a single machine; more
    # than one is a fleet, and a fleet is when per-host views start earning
    # their keep.
    def worker_hostnames
      @worker_hostnames ||= safely([]) do
        SpawnedProcess.where(created_at: RECENT_WINDOW.ago..).distinct.pluck(:hostname).compact
      end
    end

    # Every adapter this instance is configured to talk to, across all the
    # configured databases -- not just the one serving this request. An
    # instance whose queue database is MySQL is a MySQL instance even if
    # somebody is reading this from a SQLite console.
    def database_adapters
      @database_adapters ||= safely([]) do
        ActiveRecord::Base.configurations
          .configs_for(env_name: Rails.env)
          .filter_map { |config| config.adapter.to_s.presence }
          .uniq
      end
    end

    def agent_spend_usd
      @agent_spend_usd ||= safely(0) { Run.where(created_at: RECENT_WINDOW.ago..).sum(:cost_usd).to_f }
    end

    def completed_runs
      @completed_runs ||= safely(0) { Run.where(state: "succeeded", created_at: RECENT_WINDOW.ago..).count }
    end

    def repository_count
      @repository_count ||= safely(0) { Repository.where(archived_at: nil).count }
    end

    private

    # `{ "python" => ["acme/api", "acme/tools"] }`, built once from the
    # observations every repository carries.
    def detections
      @detections ||= safely({}) do
        Repository.where(archived_at: nil).where.not(plugin_signals: nil)
          .pluck(:owner, :name, :plugin_signals)
          .each_with_object({}) do |(owner, name, signals), acc|
            Array(signals).each { |plugin| (acc[plugin.to_s] ||= []) << "#{owner}/#{name}" }
          end
      end
    end

    # A signal that cannot be read is not a reason to break the page it is
    # decorating. Every caller has a defensible empty answer, and an empty
    # answer suppresses the nudge rather than inventing one.
    def safely(fallback)
      yield
    rescue StandardError => e
      Rails.logger.debug { "[plugin_signals] #{e.class}: #{e.message}" }
      fallback
    end
  end
end
