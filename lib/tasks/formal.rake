namespace :formal do
  desc "Report reconciler activity for states the Lean models prove unreachable (HOURS=24)"
  task alarms: :environment do
    hours = Integer(ENV.fetch("HOURS", "24"), 10)
    result = Formal::ProvedUnreachableAlarm.call(since: hours.hours.ago)
    puts "Watching #{result.watched_kinds.size} proved-unreachable issue kinds over the last #{hours}h."
    if result.quiet?
      puts "Quiet: none occurred."
    else
      result.sightings.each do |sighting|
        puts "SEEN #{sighting.issue_kind} (#{sighting.item_id}): #{sighting.count}x, last #{sighting.last_seen_at.iso8601}, " \
             "events #{sighting.sample_event_ids.join(', ')}"
      end
      puts "A proved-unreachable state occurred: an assumption is wrong or a model has drifted (formal/INTEGRATION.md, layer 4)."
      exit 1
    end
  end
end
