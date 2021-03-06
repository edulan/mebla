# A wrapper for slingshot  elastic-search adapter for Mongoid
module Mebla
  # Handles indexing and reindexing
  class Context    
    attr_reader  :indexed_models, :slingshot_index, :slingshot_index_name
    attr_reader  :mappings
    
    # @private
    # Creates a new context object
    def initialize            
      @indexed_models = []
      @mappings = {}
      @slingshot_index = Slingshot::Index.new(Mebla::Configuration.instance.index)
      @slingshot_index_name = Mebla::Configuration.instance.index
    end
    
    # @private
    # Adds a model to the list of indexed models
    def add_indexed_model(model, mappings = {})
      model = model.name if model.is_a?(Class)
      
      @indexed_models << model
      @indexed_models.uniq!
      @indexed_models.sort!
      
      @mappings.merge!(mappings)
    end
    
    # Deletes and rebuilds the index
    # @note Doesn't index the data, use Mebla::Context#reindex_data to rebuild the index and index the data
    # @return [nil]
    def rebuild_index
      # Only rebuild if the index exists
      raise Mebla::Errors::MeblaIndexException.new("#{@slingshot_index_name} does not exist !! use #create_index to create the index first.") unless index_exists?

      Mebla.log("Rebuilding index")      
      
      # Delete the index
      if drop_index
        # Create the index
        return build_index
      end
    end
    
    # Creates and indexes the document
    # @note Doesn't index the data, use Mebla::Context#index_data to create the index and index the data
    # @return [Boolean] true if operation is successful
    def create_index
      # Only create the index if it doesn't exist
      raise Mebla::Errors::MeblaIndexException.new("#{@slingshot_index_name} already exists !! use #rebuild_index to rebuild the index.") if index_exists?
      
      Mebla.log("Creating index")
      
      # Create the index
      build_index
    end
    
    # Deletes the index of the document
    # @return [Boolean] true if operation is successful
    def drop_index
      # Only drop the index if it exists
      return true unless index_exists?
      
      Mebla.log("Dropping index: #{self.slingshot_index_name}", :debug)
      
      # Drop the index
      result = @slingshot_index.delete
      
      Mebla.log("Dropped #{self.slingshot_index_name}: #{result.to_s}", :debug)
      
      # Check that the index doesn't exist
      !index_exists?
    end
    
    # Checks if the index exists and is available
    # @return [Boolean] true if the index exists and is available, false otherwise
    def index_exists?
      begin
        result = Slingshot::Configuration.client.get "#{Mebla::Configuration.instance.url}/#{@slingshot_index_name}/_status"
        return (result =~ /error/) ? false : true
      rescue RestClient::ResourceNotFound
        return false
      end
    end
    
    # Creates the index and indexes the data for all models or a list of models given
    # @param *models a list of symbols each representing a model name to be indexed
    # @return [nil]
    def index_data(*models)
      if models.nil? || models.empty?
        only_index = @indexed_models
      else
        only_index = models.collect{|m| m.to_s}
      end      
      
      Mebla.log("Indexing #{only_index.join(", ")}", :debug)
      
      # Build up a bulk query to save processing and time
      bulk_query = ""
      # Keep track of indexed documents
      indexed_count = {}
      
      # Create the index
      if create_index
        # Start collecting documents
        only_index.each do |model|
          Mebla.log("Indexing: #{model}")
          # Get the class
          to_index = model.camelize.constantize
          
          # Get the records    
          entries = []
          unless to_index.embedded?
            if to_index.sub_class?
              entries = to_index.any_in(:_type => [to_index.name])
            else              
              entries = to_index.any_in(:_type => [nil, to_index.name])
            end
          else
            parent = to_index.embedded_parent
            access_method = to_index.embedded_as
            
            parent.all.each do |parent_record|
              if to_index.sub_class?
                entries += parent_record.send(access_method.to_sym).any_in(:_type => [to_index.name])
              else
                entries += parent_record.send(access_method.to_sym).any_in(:_type => [nil, to_index.name])
              end
            end
          end
          
          # Save the number of entries to be indexed
          indexed_count[model] = entries.count          
          
          # Build the queries for this model          
          entries.each do |document|
            attrs = {} #document.attributes.dup # make sure we dont modify the document it self
            attrs[:id] = document.attributes["_id"] # the id is already added in the meta data of the action part of the query
            
            # only index search fields  and methods
            document.class.search_fields.each do |field|
              if document.attributes.keys.include?(field.to_s)
                attrs[field] = document.attributes[field.to_s] # attribute
              else
                attrs[field] = document.send(field) # method
              end
            end
            
            # index relational fields
            document.class.search_relations.each do |relation, fields|              
              items = document.send(relation.to_sym) # get the relation document
              
              next if items.nil?
              
              # N relation side
              if items.is_a?(Array) || items.is_a?(Mongoid::Relations::Targets::Enumerable)
                next if items.empty?
                attrs[relation] = []
                items.each do |item|
                  if fields.is_a?(Array) # given multiple fields to index
                    fields_values = {}
                    fields.each do |field|
                      if item.attributes.keys.include?(field.to_s)
                        fields_values.merge!({ field => item.attributes[field.to_s] }) # attribute
                      else
                        fields_values.merge!({ field => item.send(field) }) # method
                      end
                    end
                    attrs[relation] << fields_values
                  else # only index one field in the relation
                    if item.attributes.keys.include?(fields.to_s)
                      attrs[relation] << { fields => item.attributes[fields.to_s] } # attribute
                    else
                      attrs[relation] << { fields => item.send(fields) } # method
                    end
                  end
                end
              # 1 relation side
              else
                attrs[relation] = {}
                if fields.is_a?(Array) # given multiple fields to index
                  fields_values = {}
                  fields.each do |field|
                    if items.attributes.keys.include?(field.to_s)
                      fields_values.merge!({ field => items.attributes[field.to_s] }) # attribute
                    else
                      fields_values.merge!({ field => items.send(field) }) # method
                    end
                  end
                  attrs[relation].merge!(fields_values)
                else # only index one field in the relation
                  if items.attributes.keys.include?(fields.to_s)
                    attrs[relation].merge!({ fields => items.attributes[fields.to_s] }) # attribute
                  else
                    attrs[relation].merge!({ fields => items.send(fields) }) # method
                  end
                end
              end
            end  
            
            # If embedded get the parent id
            if document.embedded?
              parent_id = document.send(document.class.embedded_parent_foreign_key.to_sym).id.to_s        
              attrs[(document.class.embedded_parent_foreign_key + "_id").to_sym] = parent_id
              attrs[:_parent] = parent_id
              
              # Build add to the bulk query
              bulk_query << build_bulk_query(@slingshot_index_name, to_index.slingshot_type_name, document.id.to_s, attrs, parent_id)
            else
              # Build add to the bulk query
              bulk_query << build_bulk_query(@slingshot_index_name, to_index.slingshot_type_name, document.id.to_s, attrs)
            end
          end
        end
      else
        raise Mebla::Errors::MeblaIndexException.new("Could not create #{@slingshot_index_name}!!!")
      end      
      
      Mebla.log("Bulk indexing:\n#{bulk_query}", :debug)      
      
      # Send the query
      response = Slingshot::Configuration.client.post "#{Mebla::Configuration.instance.url}/_bulk", bulk_query
      
      # Only refresh the index if no error ocurred
      unless response =~ /error/                              
        # Log results
        Mebla.log("Indexed #{only_index.count} model(s) to #{self.slingshot_index_name}: #{response}")
        Mebla.log("Indexing Report:")
        indexed_count.each do |model_name, count|
          Mebla.log("Indexed #{model_name}: #{count} document(s)")
        end
        
        # Refresh the index
        refresh_index
      else
        raise Mebla::Errors::MeblaIndexException.new("Indexing #{only_index.join(", ")} failed with the following response:\n #{response}")
      end
    rescue RestClient::Exception => error
      raise Mebla::Errors::MeblaIndexException.new("Indexing #{only_index.join(", ")} failed with the following error: #{error.message}")
    end
    
    # Rebuilds the index and indexes the data for all models or a list of models given
    # @param *models a list of symbols each representing a model name to rebuild it's index
    # @return [nil]
    def reindex_data(*models)   
      Mebla.log("Rendexing: #{self.slingshot_index_name}")
      
      unless drop_index
        raise Mebla::Errors::MeblaIndexException.new("Could not drop #{@slingshot_index_name}!!!")
      end        
      
      # Create the index and index the data
      if models && !models.empty?
        index_data(models)
      else
        index_data
      end
    end
        
    # Refreshes the index
    # @return [nil]
    def refresh_index
      Mebla.log("Refreshing: #{self.slingshot_index_name}", :debug)
      
      result = @slingshot_index.refresh
      
      Mebla.log("Refreshed #{self.slingshot_index_name}: #{result}")
    end
    
    private          
    # Builds the index according to the mappings set
    # @return [Boolean] true if the index was created successfully, false otherwise
    def build_index 
      Mebla.log("Building #{self.slingshot_index_name}", :debug)
      # Create the index
      result = @slingshot_index.create :mappings => @mappings 
      
      Mebla.log("Created #{self.slingshot_index_name}: #{result.to_s}")
      
      # Check if the index exists
      index_exists?
    end
    
    # --
    # OPTIMIZE: should find a solution for not refreshing the index while indexing embedded documents
    # ++

    # Builds a bulk index query
    # @return [String]
    def build_bulk_query(index_name, type, id, attributes, parent = nil)
      attrs_to_json = ActiveSupport::JSON.encode(attributes).gsub(/\n/, " ")
      <<-eos
        { "index" : { "_index" : "#{index_name}", "_type" : "#{type}", "_id" : "#{id}"#{", \"_parent\" : \"#{parent}\"" if parent}, "refresh" : "true"} }        
        #{attrs_to_json}
      eos
    end
  end
end