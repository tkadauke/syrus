require "set"

class FilterUsage < ApplicationRecord
  SURFACES = %w[dashboard].freeze
  SUBJECTS = SmartFolder::SUBJECT_TYPES.dup.freeze

  @surface_mutex = Mutex.new
  @plugin_surfaces = Set.new
  @subject_mutex = Mutex.new
  @plugin_subjects = Set.new

  belongs_to :user

  validates :surface, presence: true, inclusion: { in: ->(_) { surfaces } }
  validates :subject, presence: true, inclusion: { in: ->(_) { subjects } }
  validates :fingerprint, presence: true
  validates :filter_node, presence: true
  validates :label, presence: true
  validates :use_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :fingerprint, uniqueness: { scope: [ :user_id, :surface, :subject ] }

  class << self
    def register_surface(surface)
      @surface_mutex.synchronize { @plugin_surfaces.add(surface.to_s) }
    end

    def unregister_surface(surface)
      @surface_mutex.synchronize { @plugin_surfaces.delete(surface.to_s) }
    end

    def reset_plugin_surfaces!
      @surface_mutex.synchronize { @plugin_surfaces = Set.new }
    end

    def surfaces
      @surface_mutex.synchronize { (SURFACES + @plugin_surfaces.to_a).freeze }
    end

    def register_subject(subject)
      @subject_mutex.synchronize { @plugin_subjects.add(subject.to_s) }
    end

    def unregister_subject(subject)
      @subject_mutex.synchronize { @plugin_subjects.delete(subject.to_s) }
    end

    def reset_plugin_subjects!
      @subject_mutex.synchronize { @plugin_subjects = Set.new }
    end

    def subjects
      @subject_mutex.synchronize { (SUBJECTS + @plugin_subjects.to_a).freeze }
    end
  end
end
