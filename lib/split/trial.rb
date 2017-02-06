module Split
  class Trial
    attr_accessor :experiment
    attr_accessor :split_id
    attr_accessor :goals

    def initialize(attrs = {})
      self.experiment = attrs[:experiment]  if !attrs[:experiment].nil?
      self.split_id = attrs[:split_id] if !attrs[:split_id].nil?
      self.goals = attrs[:goals].nil? ? [] : attrs[:goals]
    end

    def alternative
      @alternative ||=  if experiment.has_winner?
                          experiment.winner
                        else
                          choose
                        end
    end

    def complete!
      if alternative
        if self.goals.empty?
          alternative.increment_completion
        else
          self.goals.each {|g| alternative.increment_completion(g)}
        end
      end
    end

    def choose!
      choose
      record!
    end

    def record!
      alternative.increment_participation
    end

    def choose
      self.alternative = experiment.next_alternative(split_id)
    end

    def alternative=(alternative)
      @alternative = if alternative.kind_of?(Split::Alternative)
        alternative
      else
        self.experiment.alternatives.find{|a| a.name == alternative }
      end
    end
  end
end
