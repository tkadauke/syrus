module ApprovalNotifications
  class Urgency
    LEVELS = { "low" => 0, "normal" => 1, "urgent" => 2 }.freeze

    def self.for(risk)
      { "critical" => Urgent, "high" => Urgent, "medium" => Normal, "low" => Low }.fetch(risk.to_s, Normal).new
    end

    def name = raise NotImplementedError
    def batch? = true

    class Low < Urgency
      def name = "low"
    end

    class Normal < Urgency
      def name = "normal"
    end

    class Urgent < Urgency
      def name = "urgent"
      def batch? = false
    end
  end
end
