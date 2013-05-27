module TentD

  class Feed

    DEFAULT_PAGE_LIMIT = 25.freeze
    MAX_PAGE_LIMIT = 200.freeze

    require 'tentd/feed/query'

    attr_reader :env
    def initialize(env)
      @env = env
    end

    def params
      env['params']
    end

    def query
      q = Query.new(Model::Post)

      q.sort_columns = case params['sort_by']
      when 'published_at'
        ['published_at DESC', 'version_published_at DESC']
      when 'version.published_at'
        'version_published_at DESC'
      else
        ['received_at DESC', 'version_received_at DESC']
      end

      q.query_conditions << "#{q.table_name}.user_id = ?"
      q.query_bindings << env['current_user'].id

      if params['types']
        requested_types = params['types'].uniq.map { |uri| TentType.new(uri) }

        type_ids_q = Query.new(Model::Type)
        type_ids_q.select_columns = :id

        requested_types.each do |type|
          type_ids_q.query_conditions << ["AND", "base = ?"]
          type_ids_q.query_bindings << type.base

          if type.has_fragment?
            if type.fragment.nil?
              type_ids_q.query_conditions.last << "fragment IS NULL"
            else
              type_ids_q.query_conditions.last << "fragment = ?"
              type_ids_q.query_bindings << type.fragment
            end
          end
        end

        type_ids = type_ids_q.all(:conditions_sep => 'OR').map(&:id)

        q.query_conditions << "type_id IN ?"
        q.query_bindings << type_ids
      end

      if params['entities']
        q.query_conditions << "entity IN ?"
        q.query_bindings << params['entities'].split(',').uniq
      end

      if params['mentions']
        mentions_table = Model::Mention.table_name
        q.join("INNER JOIN #{mentions_table} ON #{mentions_table}.post_id = #{q.table_name}.id")

        mentions = Array(params['mentions']).map do |mentions_param|
          mentions_param.split(',').map do |mention|
            entity, post = mention.split(' ')
            mention = { :entity => entity }
            mention[:post] = post if post
            mention
          end
        end

        # fetch entity ids
        flat_mentions = mentions.flatten
        entities = flat_mentions.map { |mention| mention[:entity] }
        entities_q = Query.new(Model::Entity)
        entities_q.query_conditions << "entity IN ?"
        entities_q.query_bindings << entities
        entities_q.all.each do |entity|
          index = entities.index(entity.entity)
          flat_mentions[index][:entity_id] = entity.id
        end

        mentions.each do |_mentions|
          mentions_bindings = []
          mentions_conditions = ['OR'].concat(_mentions.map { |mention|
            mentions_bindings << mention[:entity_id]
            if mention[:post]
              mentions_bindings << mention[:post]
              "(#{mentions_table}.entity_id = ? AND #{mentions_table}.post = ?)"
            else
              "#{mentions_table}.entity_id = ?"
            end
          })

          q.query_conditions << mentions_conditions
          q.query_bindings.push(*mentions_bindings)
        end
      end

      if params['limit']
        q.limit = [params['limit'].to_i, MAX_PAGE_LIMIT].min
      else
        q.limit = DEFAULT_PAGE_LIMIT
      end

      q
    end

    def fetch_query
      query.all
    end

    def as_json(options = {})
      models = fetch_query
      {
        :pages => {},
        :posts => models.map(&:as_json)
      }
    end
  end

end
