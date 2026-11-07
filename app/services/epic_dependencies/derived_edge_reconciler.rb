module EpicDependencies
  class DerivedEdgeReconciler
    class << self
      def reconcile(epic_id:, depends_on_epic_id:)
        return if epic_id.blank? || depends_on_epic_id.blank? || epic_id == depends_on_epic_id

        edge = EpicDependency.where(epic_id: epic_id, depends_on_epic_id: depends_on_epic_id)
        derived_edges = edge.where(derived: true)

        if edge.where(derived: false).exists? || !supporting_job_dependency?(epic_id:, depends_on_epic_id:)
          derived_edges.destroy_all
        else
          derived_edges.first_or_create!
        end
      end

      def reconcile_job_dependency(dependency)
        job_edge_pairs(dependency).each do |epic_id, depends_on_epic_id|
          reconcile(epic_id:, depends_on_epic_id:)
        end
      end

      def reconcile_explicit_edge(dependency)
        record_edge_pairs(dependency).each do |epic_id, depends_on_epic_id|
          reconcile(epic_id:, depends_on_epic_id:)
        end
      end

      private

      def supporting_job_dependency?(epic_id:, depends_on_epic_id:)
        JobDependency.where(
          job_id: Job.where(epic_id: epic_id).select(:id),
          depends_on_job_id: Job.where(epic_id: depends_on_epic_id).select(:id)
        ).exists?
      end

      def job_edge_pairs(dependency)
        current = [ dependency.job_id, dependency.depends_on_job_id ]
        previous = [ previous_value(dependency, "job_id"), previous_value(dependency, "depends_on_job_id") ]

        [ current, previous ].uniq.filter_map do |job_id, depends_on_job_id|
          dependent_epic_id = Job.where(id: job_id).pick(:epic_id)
          upstream_epic_id = Job.where(id: depends_on_job_id).pick(:epic_id)
          [ dependent_epic_id, upstream_epic_id ] if dependent_epic_id.present? && upstream_epic_id.present?
        end
      end

      def record_edge_pairs(dependency)
        current = [ dependency.epic_id, dependency.depends_on_epic_id ]
        previous = [ previous_value(dependency, "epic_id"), previous_value(dependency, "depends_on_epic_id") ]
        [ current, previous ].uniq
      end

      def previous_value(record, attribute)
        record.previous_changes.fetch(attribute, [ record.public_send(attribute) ]).first
      end
    end
  end
end
