require 'split/zscore'

# TODO - take out require and implement using file paths?

module Split
  class Alternative
    attr_accessor :name
    attr_accessor :experiment_name
    attr_accessor :weight

    include Zscore

    def initialize(name, experiment_name)
      @experiment_name = experiment_name
      if Hash === name
        @name = name.keys.first
        @weight = name.values.first
      else
        @name = name
        @weight = 1
      end
    end

    def to_s
      name
    end

    def goals
      self.experiment.goals
    end

    def participant_count
      Split.redis.with do |conn|
        conn.hget(key, 'participant_count').to_i
      end
    end

    def participant_count=(count)
      Split.redis.with do |conn|
        conn.hset(key, 'participant_count', count.to_i)
      end
    end

    def completed_count(goal = nil)
      field = set_field(goal)
      ret = Split.redis.with do |conn|
        conn.hget(key, field).to_i
      end
      # the return value should always be an integer
      return (ret == [] ? 0 : ret )
    end

    def all_completed_count
      if goals.empty?
        completed_count
      else
        goals.inject(completed_count) do |sum, g|
          sum + completed_count(g)
        end
      end
    end

    def unfinished_count
      participant_count - all_completed_count
    end

    def set_field(goal, unique = false)
      if unique
        field = "unique_completed_count"
      else
        field = "completed_count"
      end
      field += ":" + goal unless goal.nil?
      return field
    end

    def set_completed_count (count, goal = nil)
      field = set_field(goal)
      Split.redis.with do |conn|
        conn.hset(key, field, count.to_i)
      end
    end

    def increment_participation
      Split.redis.with do |conn|
        conn.hincrby key, 'participant_count', 1
      end
    end

    def increment_completion(goal = nil)
      field = set_field(goal)
      Split.redis.with do |conn|
        conn.hincrby(key, field, 1)
      end
    end

    def increment_unique_completion(goal = nil)
      field = set_field(goal, true)
      Split.redis.with do |conn|
        conn.hincrby(key, field, 1)
      end
    end

    def control?
      experiment.control.name == self.name
    end

    def conversion_rate(goal = nil)
      return 0 if participant_count.zero?
      (completed_count(goal).to_f)/participant_count.to_f
    end

    def experiment
      Split::Experiment.find(experiment_name)
    end

    def z_score(goal = nil)
      # p_a = Pa = proportion of users who converted within the experiment split (conversion rate)
      # p_c = Pc = proportion of users who converted within the control split (conversion rate)
      # n_a = Na = the number of impressions within the experiment split
      # n_c = Nc = the number of impressions within the control split

      control = experiment.control
      alternative = self

      return 'N/A' if control.name == alternative.name

      p_a = alternative.conversion_rate(goal)
      p_c = control.conversion_rate(goal)

      n_a = alternative.participant_count
      n_c = control.participant_count
      
      begin
        z_score = Split::Zscore.calculate(p_a, n_a, p_c, n_c)
      rescue
        return 'N/A'
      end
    end

    def save
      Split.redis.with do |conn|
        conn.hsetnx key, 'participant_count', 0
        conn.hsetnx key, 'completed_count', 0
      end
    end

    def validate!
      unless String === @name || hash_with_correct_values?(@name)
        raise ArgumentError, 'Alternative must be a string'
      end
    end

    def reset
      Split.redis.with do |conn|
        conn.hmset key, 'participant_count', 0, 'completed_count', 0
        unless goals.empty?
          goals.each do |g|
            field = "completed_count:#{g}"
            conn.hset key, field, 0
          end
        end
      end
    end

    def delete
      Split.redis.with do |conn|
        conn.del(key)
      end
    end

    private

    def hash_with_correct_values?(name)
      Hash === name && String === name.keys.first && Float(name.values.first) rescue false
    end

    def key
      "#{experiment_name}:#{name}"
    end
  end
end
