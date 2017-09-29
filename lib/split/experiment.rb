module Split
  class Experiment
    attr_accessor :name
    attr_writer :algorithm
    attr_accessor :resettable
    attr_accessor :goals
    attr_accessor :alternatives
    attr_accessor :max_participant_count
    attr_accessor :wiki_url
    
    DEFAULT_OPTIONS = {
      :resettable => true,
    }

    def initialize(name, options = {})
      options = DEFAULT_OPTIONS.merge(options)

      @name = name.to_s

      alternatives = extract_alternatives_from_options(options)

      if alternatives.empty? && (exp_config = Split.configuration.experiment_for(name))
        set_alternatives_and_options(
          alternatives: load_alternatives_from_configuration,
          goals: load_goals_from_configuration,
          resettable: exp_config[:resettable],
          algorithm: exp_config[:algorithm],
          max_participant_count: exp_config[:max_participant_count]
        )
      else
        set_alternatives_and_options(
          alternatives: alternatives,
          goals: options[:goals],
          resettable: options[:resettable],
          algorithm: options[:algorithm],
          max_participant_count: options[:max_participant_count]
        )
      end
    end

    def set_alternatives_and_options(options)
      self.alternatives = options[:alternatives]
      self.goals = options[:goals]
      self.resettable = options[:resettable]
      self.algorithm = options[:algorithm]
      unless options[:max_participant_count].nil?
        self.max_participant_count = options[:max_participant_count].to_i
      end
    end

    def extract_alternatives_from_options(options)
      alts = options[:alternatives] || []

      if alts.length == 1
        if alts[0].is_a? Hash
          alts = alts[0].map{|k,v| {k => v} }
        end
      end

      alts
    end

    def self.all
      ExperimentCatalog.all
    end

    # Return experiments without a winner (considered "active") first
    def self.all_active_first
      ExperimentCatalog.all_active_first
    end

    def self.find(name)
      ExperimentCatalog.find(name)
    end

    def self.find_or_create(label, *alternatives)
      ExperimentCatalog.find_or_create(label, *alternatives)
    end

    def save
      validate!

      Split.redis.with do |conn|
        
        if new_record?
          conn.sadd(:experiments, name)
          start unless Split.configuration.start_manually
          @alternatives.reverse.each {|a| conn.lpush(name, a.name)}
          @goals.reverse.each {|a| conn.lpush(goals_key, a)} unless @goals.nil?
        else
          existing_alternatives = load_alternatives_from_redis
          existing_goals = load_goals_from_redis
          unless existing_alternatives == @alternatives.map(&:name) && existing_goals == @goals
            reset
            @alternatives.each(&:delete)
            delete_goals
            conn.del(@name)
            @alternatives.reverse.each {|a| conn.lpush(name, a.name)}
            @goals.reverse.each {|a| conn.lpush(goals_key, a)} unless @goals.nil?
          end
        end

        conn.hset(experiment_config_key, :resettable, resettable)
        conn.hset(experiment_config_key, :algorithm, algorithm.to_s)
        conn.hset(experiment_config_key, :max_participant_count, max_participant_count) unless max_participant_count.nil?
      end
      self
    end

    def validate!
      if @alternatives.empty? && Split.configuration.experiment_for(@name).nil?
        raise ExperimentNotFound.new("Experiment #{@name} not found")
      end
      @alternatives.each {|a| a.validate! }
      unless @goals.nil? || goals.kind_of?(Array)
        raise ArgumentError, 'Goals must be an array'
      end
    end

    def new_record?
      Split.redis.with do |conn|
      !conn.exists(name)
      end
    end

    def to_hash
      {
        version: self.version,
        algorithm: self.algorithm,
        resettable: self.resettable,
        started_at: self.start_time,
        ended_at: self.end_time
      }
    end

    def ==(obj)
      self.name == obj.name
    end

    def [](name)
      alternatives.find{|a| a.name == name}
    end

    def wiki_url
      @wiki_url ||= load_wiki_url_from_redis
    end

    def algorithm
      @algorithm ||= Split.configuration.algorithm
    end

    def max_participant_count=(max_participant_count)
      @max_participant_count = max_participant_count.to_i
    end

    def algorithm=(algorithm)
      @algorithm = algorithm.is_a?(String) ? algorithm.constantize : algorithm
    end

    def resettable=(resettable)
      @resettable = resettable.is_a?(String) ? resettable == 'true' : resettable
    end

    def alternatives=(alts)
      @alternatives = alts.map do |alternative|
        if alternative.kind_of?(Split::Alternative)
          alternative
        else
          Split::Alternative.new(alternative, @name)
        end
      end
    end
    
    def wiki_url= url
      @wiki_url = url
      Split.redis.with do |conn|
        conn.hset(:wiki_urls, @name, @wiki_url)
      end
    end
    
    def winner
      Split.redis.with do |conn|
        if w = conn.hget(:experiment_winner, name)
          Split::Alternative.new(w, name)
        else
          nil
        end
      end
    end

    def has_enough_participants?
      if max_participant_count.nil? # it's never enough if no max participant count is set
        false
      elsif max_participant_count > participant_count # this can trigger as many as 4 Redis queries
        false
      else
        true
      end
    end

    def has_winner?
      @has_winner.nil? ? !winner.nil? : @has_winner
    end
    
    def has_winner!
      @has_winner = true
    end
    
    def has_no_winner!
      @has_winner = false
    end

    def winner=(winner_name)
      Split.redis.with do |conn|
        conn.hset(:experiment_winner, name, winner_name.to_s)
      end
      set_end_time
      delete_participants
      delete_finished
      alternatives.each(&:flatten_values)
    end

    def participant_count
      alternatives.inject(0){|sum,a| sum + a.participant_count}
    end

    def control
      alternatives.first
    end

    def reset_winner
      Split.redis.with do |conn|
        conn.hdel(:experiment_winner, name)
      end
    end

    def end_time
      Split.redis.with do |conn|
        t = conn.hget(:experiment_end_times, @name)
        if t
          # Check if stored time is an integer
          if t =~ /^[-+]?[0-9]+$/
            t = Time.at(t.to_i)
          else
            t = Time.parse(t)
          end
        end
      end
    end

    def set_end_time
      Split.redis.with do |conn|
        conn.hset(:experiment_end_times, name, Time.now.to_i)
      end
      Split.configuration.on_experiment_end.call(self)
    end

    def start
      Split.redis.with do |conn|
        conn.hset(:experiment_start_times, @name, Time.now.to_i)
      end
    end

    def start_time
      Split.redis.with do |conn|
        t = conn.hget(:experiment_start_times, @name)
        if t
          # Check if stored time is an integer
          if t =~ /^[-+]?[0-9]+$/
            t = Time.at(t.to_i)
          else
            t = Time.parse(t)
          end
        end
      end
    end
    
    #TODO: This currently only works with WeightedSample algorithm. 
    def random_alternatives(num_participants)
      if winner
        Array.new(num_participants, winner)
      else
        algorithm.choose_alternatives(self, num_participants)
      end
    end

    def random_alternative(split_id)
      if alternatives.length > 1
        algorithm.choose_alternative(self, split_id)
      else
        alternatives.first
      end
    end

    def version
      Split.redis.with do |conn|
        @version ||= (conn.get("#{name.to_s}:version").to_i || 0)
      end
    end

    def increment_version
      Split.redis.with do |conn|
        @version = conn.incr("#{name}:version")
      end
    end

    def key(goal=nil)
      if version.to_i > 0
        if goal
          "#{name}:#{version}:#{goal}"
        else
          "#{name}:#{version}"
        end
      else
        if goal
          "#{name}:#{goal}"
        else
          "#{name}"
        end
      end
    end

    def goals_key
      "#{name}:goals"
    end

    def finished?(split_id, goal = nil)
      @finished ||= {}

      goalkey = goal || "nogoal"

      if !@finished[split_id].nil? && !@finished[split_id][goalkey].nil?
        return @finished[split_id][goalkey]
      else
        key = "#{self.key}:finished"
        key << ":#{goal}" if goal
        value = Split.redis.with do |conn|
          conn.sismember(key, split_id)
        end

        @finished[split_id] ||= {}
        @finished[split_id][goalkey] = value

        return value
      end
    end

    def cache_finished!(split_id, value, goal = nil)
      @finished ||= {}

      @finished[split_id] ||= {}

      if goal
        @finished[split_id][goal] = value
      else
        @finished[split_id]["nogoal"] = value
      end
    end

    def self.preload_participating!(experiments, split_ids)
      experiments = Array(experiments)
      split_ids = Array(split_ids)

      experiments_metadata = []
      experiments.each do |experiment|
        split_ids.each do |split_id|
          key = "#{experiment.key}:participants"

          experiments_metadata << {
              :key => key,
              :experiment => experiment,
              :split_id => split_id
          }
        end
      end

      if experiments_metadata.present?
        results = Split.redis.with do |conn|
          conn.pipelined do
            experiments_metadata.each do |metadata|
              conn.sismember metadata[:key], metadata[:split_id]
            end
          end
        end

        results.each_with_index do |result, index|
          metadata = experiments_metadata[index]
          metadata[:experiment].cache_participating!(metadata[:split_id], result)
        end
      end
    end

    def self.preload_finished!(experiments, goals, split_ids)
      experiments = Array(experiments)
      split_ids = Array(split_ids)

      experiments_metadata = []
      goals.each do |goal|
        experiments.each do |experiment|
          split_ids.each do |split_id|
            key = "#{experiment.key}:finished:#{goal}"

            experiments_metadata << {
                :key => key,
                :experiment => experiment,
                :goal => goal,
                :split_id => split_id
            }
          end
        end
      end

      if experiments_metadata.present?
        results = Split.redis.with do |conn|
          conn.pipelined do
            experiments_metadata.each do |metadata|
              conn.sismember metadata[:key], metadata[:split_id]
            end
          end
        end

        results.each_with_index do |result, index|
          metadata = experiments_metadata[index]
          metadata[:experiment].cache_finished!(metadata[:split_id], result, metadata[:goal])
        end
      end
    end

    def finish!(split_id, goal = nil)
      key = "#{self.key}:finished"
      key << ":#{goal}" if goal
      Split.redis.with do |conn|
        conn.sadd(key, split_id)
      end

      cache_finished!(split_id, true, goal)
    end

    def participate!(split_ids)
      split_ids = Array(split_ids)
      return if split_ids.blank?

      key = "#{self.key}:participants"
      Split.redis.with do |conn|
        conn.sadd(key, split_ids)
      end

      cache_participating!(split_ids, true)
    end

    def cache_participating!(split_ids, value)
      split_ids = Array(split_ids)

      @participating ||= {}

      split_ids.each do |split_id|
        @participating[split_id] = value
      end
    end

    def participating?(split_id)
      @participating ||= {}

      if !@participating[split_id].nil?
        return @participating[split_id]
      else
        key = "#{self.key}:participants"
        value = Split.redis.with do |conn|
          conn.sismember(key, split_id)
        end

        @participating[split_id] = value

        return value
      end
    end

    def resettable?
      resettable
    end

    def reset
      alternatives.each(&:reset)
      reset_winner
      delete_participants
      delete_finished
      Split.configuration.on_experiment_reset.call(self)
      increment_version
      Split.configuration.reset
    end

    def delete
      Split.redis.with do |conn|
        alternatives.each(&:delete)
        reset_winner
        conn.srem(:experiments, name)
        conn.del(name)
        delete_participants
        delete_finished
        delete_goals
        Split.configuration.on_experiment_delete.call(self)
        increment_version
        Split.configuration.reset
      end
    end

    def delete_participants
      Split.redis.with do |conn|
        new_key = "gc:lists:#{conn.incr("gc:index")}"
        conn.rename("#{self.key}:participants", new_key)
        Split.configuration.on_garbage_collection.call(new_key)
      end
    end

    def delete_finished
      Split.redis.with do |conn|
        key = "#{self.key}:finished"
        new_key = "gc:lists:#{conn.incr("gc:index")}"
        conn.rename(key, new_key)
        Split.configuration.on_garbage_collection.call(new_key)
        (goals).each do |goal|
          new_key = "gc:lists:#{conn.incr("gc:index")}"
          conn.rename("#{key}:#{goal}", new_key)
          Split.configuration.on_garbage_collection.call(new_key)
        end
      end
    end

    def delete_goals
      Split.redis.with do |conn|
        conn.del(goals_key)
      end
    end

    def load_from_redis
      Split.redis.with do |conn|
        exp_config = conn.hgetall(experiment_config_key)
        self.resettable = exp_config['resettable']
        self.algorithm = exp_config['algorithm']
        self.alternatives = load_alternatives_from_redis
        self.goals = load_goals_from_redis
        unless exp_config['max_participant_count'].nil?
          self.max_participant_count = exp_config['max_participant_count'].to_i
        end
      end
    end

    protected

    def experiment_config_key
      "experiment_configurations/#{@name}"
    end

    def load_goals_from_configuration
      goals = Split.configuration.experiment_for(@name)[:goals]
      if goals.nil?
        goals = []
      else
        goals.flatten
      end
    end

    def load_goals_from_redis
      Split.redis.with do |conn|
        conn.lrange(goals_key, 0, -1)
      end
    end

    def load_alternatives_from_configuration
      alts = Split.configuration.experiment_for(@name)[:alternatives]
      raise ArgumentError, "Experiment configuration is missing :alternatives array" unless alts
      if alts.is_a?(Hash)
        alts.keys
      else
        alts.flatten
      end
    end

    def load_wiki_url_from_redis
      Split.redis.with do |conn|
        @wiki_url = conn.hget(:wiki_urls, @name)
      end
    end

    def load_alternatives_from_redis
      Split.redis.with do |conn|
        case conn.type(@name)
        when 'set' # convert legacy sets to lists
          alts = conn.smembers(@name)
          conn.del(@name)
          alts.reverse.each {|a| Split.redis.lpush(@name, a) }
          conn.lrange(@name, 0, -1)
        else
          conn.lrange(@name, 0, -1)
        end
      end
    end
  end
end
