require "rviz"
require "yaml"
require 'i18n'
require 'active_support/lazy_load_hooks'
require 'active_support/core_ext/string'

class Fields
  attr_accessor :name, :erd_label, :type, :edge
  def as_row
    str = type == "function" ? '+ ' + name : '- ' + name
    str += ":" + type unless type == "function" if type
    str += ", #{erd_label}" if erd_label and erd_label.size > 0
    str
  end
end

class Model
  attr_accessor :name, :erd_label, :attrs, :fields, :tag, :parent
  def initialize 
    @attrs = Hash.new
    @fields = Array.new 
  end

  def title
    "- [#{parent ? parent.camelize + '::' : ''}#{name.camelize}:#{erd_label}] -"
  end
end

class MongoidErd
  
  def initialize config = {}
    @config = config
      # tag: [], tags: {}, include = [], exclude = [], model_dir = ""
    
    # parse the option file
    if @config[:conf_file] and File.exists? @config[:conf_file]
      yml = YAML.load(File.open(@config[:conf_file], 'r:utf-8').read)
      @config[:tags] = yml["tags"]
      @config[:title] = yml["title"]
    else
      raise "#{@config[:conf_file]} does not exists" if @config[:conf_file]
    end
    
    # merge tag attributes recursively
    @config[:tags].each do |t,v|
      tv = @config[:tags]["_default"].clone || {} 
      p = nil
      t.split('.').each do |pt|
        p = p ? [p, pt].join('.') : pt # merge in order: tv < a < a.b < a.b.c, ...
        # puts "merge from #{p} to #{t}"
        tv.merge! @config[:tags][p] if @config[:tags][p]
      end
      @config[:tags][t] = tv
    end

    @models = Hash.new
  end

  def set key, value
    @config[key] = value
  end

  def get key
    @config[key]
  end

  def parse_erd o, line
    if /erd\{(?<yml_>.+?)\}:?/ =~ line
      o.attrs.merge! YAML.load(yml_) if yml_
    end
    if /erd(\{.+?\})?\s*:?\s+(?<label_>.+)/ =~ line
      o.erd_label = label_ if label_
    end
  end

  # parse the fold contains mongoid source
  def parse
    raise "directory #{@config[:model_dir]} not exists" unless File.directory? @config[:model_dir]
    Dir["#{@config[:model_dir]}/*.rb"].each do |file|
      crt_model = Model.new
      model_attrs_ = Hash.new
      in_public = true
      File.open(file, 'r:utf-8').each do |line|
        line.chomp!

        # erd_tag and attr
        if /^[\#\s]*erd_tag\:?\s*(?<tag_>[\w\.]+)/ =~ line
          crt_model.tag = tag_ 
          crt_model.attrs = @config[:tags][tag_]
        end

        # catch class definition
        if /^\s*class\s+(?<name_>\w+)/ =~ line
          crt_model.name = name_.underscore 
          self.parse_erd crt_model, line
          if /^\s*class\s+\w+\s+\<\s+(?<parent_>\w+)/ =~ line
            crt_model.parent = parent_.underscore if parent_
          end
        end
        
        # catch functions
        in_public = true if /public\:/ =~ line
        in_public = false if /private\:/ =~ line

        if /^\s*def\s+(?<func_>[^#]+)\s*/ =~ line
          field_ = Fields.new
          func_ = func_.gsub(/[{}]/, '')
          field_.name, field_.type = func_, 'function'
          self.parse_erd field_, line # parse erd attr and label
          # arbitrage link
          if /\-\>\s*(?<name_>\w+)(\{(?<attrs_>.+)\})?/ =~ line
            attrs = {}
            attrs = YAML.load(attrs_) if attrs_
            field_.edge = [name_, '', attrs]
          end
          crt_model.fields << field_ 
        end

        # catch field
        if /^\s*field\s+\:(?<name_>\w+).*/ =~ line #\:?type\:?\s*(?<type_>[A-Za-z_0-9\:]+)/ =~ line
          field_ = Fields.new
          field_.name = name_ #, type_
          self.parse_erd field_, line # parse erd attr and label
          # arbitrage link
          if /\-\>\s*(?<name_>\w+)(\{(?<attrs_>.+)\})?/ =~ line
            attrs = {}
            attrs = YAML.load(attrs_) if attrs_
            field_.edge = [name_, '', attrs]
          end
          crt_model.fields << field_ 
        end

        # catch relations
        if /^\s*(?<rel_>embeds_many|embeds_one|has_many|has_one|belongs_to|embedded_in)\s+\:(?<name_>\w+)\s*(\,.*\:?as\:?\s*(?<as_>\w+))?/ =~ line
          field_ = Fields.new
          field_.name, field_.type = rel_, name_
          #field_.name = "#{rel_} (as #{as_})" if as_
          self.parse_erd field_, line # parse erd attr and label
          crt_model.fields << field_ 
          #if %w[belongs_to embedded_in embeds_one has_one].include? rel_

          if %w[embeds_many has_many].include? rel_
            name_ = name_.singularize
          end

          
          #if /^.*\:class_name\s*=>\s*\'Steak\:\:(?<parent_>\w+)\s*.*/ =~ line
          # change to support  format: belongs_to :owner , class_name : "HpPerson",inverse_of: :hp_horses
          if /^.*class_name\s*\:\s*[\'\"](?<parent_>\w+)\s*.*/ =~ line
            name_ = parent_
          end

          field_.edge = [name_, '', {label: rel_, arrowhead: 'normal'}]
          #end
        end
        
        # common extension field
        if /^\s*symbolize\s+\:(?<name>\w+)\s*\,.*\:?in\:?.*(?<in_>\[.+\])/ =~ line
          field_ = Fields.new
          field_.name, field_.type = name_, "symbolized in #{in_}"
          self.parse_erd field_, line # parse erd attr and label
          crt_model.fields << field_ 
        end

        if /^\s*state_machine\s+\:(?<state_>\w+)/ =~ line
          field_ = Fields.new
          field_.name = state_ == "initial" ? "state" : state_
          field_.type = "state_machine"
          self.parse_erd field_, line # parse erd attr and label
          crt_model.fields << field_ 
        end

        if /\s*as_enum\s+\:(?<name_>\w+)\s*\,\s*(?<enum_>[^#]+)/ =~ line
          field_ = Fields.new
          field_.name = name_
          field_.type = "[ENUM] " + enum_ 
          self.parse_erd field_, line # parse erd attr and label
          crt_model.fields << field_ 
        end

      end # open and parse one file

      # assign attributes at the last moment
      crt_model.attrs.merge! model_attrs_

      # if config.include/tag, default to exclude_it = true
      if @config[:include].size > 0 or @config[:tag].size > 0
        include_it = false
      else
        include_it = true
      end

      # if in the include list, include it
      include_it = true if @config[:include] and @config[:include].include? crt_model.name
      @config[:tag].each do |t|
        include_it = true if t == crt_model.tag or /^#{t}(\..+)?/.match(crt_model.tag)
      end

      include_it = false if @config[:exclude].include? crt_model.name
      @models[crt_model.parent ? crt_model.parent.camelize + '::' + crt_model.name : crt_model.name] = crt_model if include_it
    end # open directory
    self
  end

  def output 
    g = Rviz::Graph.new @config[:title], {rankdir: 'LR', dpi: 300}

    @models.each do |mname, model|
      g.add_record((model.parent ? model.parent.camelize + '::' : '') + model.name.camelize, model.attrs)
      g.node((model.parent ? model.parent.camelize + '::' : '') + model.name.camelize).add_row(model.title, true)
      model.fields.each do |field|
        g.node((model.parent ? model.parent.camelize + '::' : '') + model.name.camelize).add_row(field.as_row, true, 'l')
        if field.edge
          to_node, to_anchor, attrs = field.edge[0].underscore, field.edge[1], field.edge[2]
          unless @models[to_node]
            g.add(to_node.camelize, 'oval', {style:'filled', fillcolor:'grey', color:'grey'})
            to_anchor = ''
          end
          g.link((model.parent ? model.parent.camelize + '::' : '') + model.name.camelize, field.as_row, to_node.camelize, to_anchor, attrs)
        end
      end

      # relations
      if model.parent
        unless @models[model.parent]
          g.add(model.parent.camelize, 'oval', {style:'filled', fillcolor:'grey', color:'grey'})
        end
        g.link((model.parent ? model.parent.camelize + '::' : '') + model.name.camelize, model.title, model.parent.camelize, '', {arrowhead: 'onormal'})
      end
    end

    g.output
  end

end
