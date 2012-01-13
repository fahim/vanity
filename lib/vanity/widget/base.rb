module Vanity

  # A widget is an object that implements two methods: +name+ and +values+.  It
  # can also respond to addition methods (+track!+, +bounds+, etc), these are
  # optional.
  #
  # This class implements a basic widget that tracks data and stores it in the
  # database.  You can use this as the basis for your widget, or as reference
  # for the methods your widget must and can implement.
  #
  # @since 1.1.0
  class Widget

    # These methods are available when defining a widget in a file loaded
    # from the +experiments/widgets+ directory.
    #
    # For example:
    #   $ cat experiments/widgets/yawn_sec
    #   widget "Yawns/sec" do
    #     description "Most boring widget ever"
    #   end
    module Definition
      
      attr_reader :playground

      # Defines a new widget, using the class Vanity::Widget.
      def widget(id_end, &block)
        id = "#{@file_path}.#{id_end}"
        @widget_id = id
        fail "Widget #{@widget_id} already defined in playground" if playground.widgets[@widget_id]
        
        widget = Widget.new(playground, id)
        widget.name(@widget_id)
        widget.instance_eval &block
        playground.widgets[@widget_id] = widget
      end

      def new_binding(playground, file_path)
        @playground, @file_path = playground, file_path
        binding
      end

    end

    class << self

      # Helper method to return description for a widget.
      #
      # A widget object may have a +description+ method that returns a detailed
      # description.  It may also have no description, or no +description+
      # method, in which case return +nil+.
      # 
      # @example
      #   puts Vanity::Widget.description(widget)
      def description(widget)
        widget.description if widget.respond_to?(:description)
      end
      
      def name(widget)
        widget.name if widget.respond_to?(:name)
      end

      # Helper method to return bounds for a widget.
      #
      # A widget object may have a +bounds+ method that returns lower and upper
      # bounds.  It may also have no bounds, or no +bounds+ # method, in which
      # case we return +[nil, nil]+.
      # 
      # @example
      #   upper = Vanity::Widget.bounds(widget).last
      def bounds(widget)
        widget.respond_to?(:bounds) && widget.bounds || [nil, nil]
      end

      def metrics(widget)
        widget.metrics if widget.respond_to?(:metrics)
      end

      # Playground uses this to load widget definitions.
      def load(playground, stack, file)
        fail "Circular dependency detected: #{stack.join('=>')}=>#{file}" if stack.include?(file)
        source = File.read(file)
        stack.push file
        id = File.basename(file, ".rb").downcase.gsub(/\W/, "_").to_sym
        context = Object.new
        context.instance_eval do
          extend Definition
          widget = eval(source, context.new_binding(playground, id), file)
          widget
        end
      rescue
        error = NameError.exception($!.message, id)
        error.set_backtrace $!.backtrace
        raise error
      ensure
        stack.pop
      end

    end


    # Takes playground (need this to access Redis), friendly name and optional
    # id (can infer from name).
    def initialize(playground, id)
      @playground = playground
      @id = id.downcase.gsub(/\W+/, '_').to_sym
      @widget_id = id
      @options = {}
    end

    # This method returns the acceptable bounds of a widget as an array with
    # two values: low and high.  Use nil for unbounded.
    #
    # Alerts are created when widget values exceed their bounds.  For example,
    # a widget of user registration can use historical data to calculate
    # expected range of new registration for the next day.  If actual widget
    # falls below the expected range, it could indicate registration process is
    # broken.  Going above higher bound could trigger opening a Champagne
    # bottle.
    #
    # The default implementation returns +nil+.
    def bounds
    end

    #  -- Reporting --
    
    # Human readable widget name.  All widgets must implement this method.
    attr_accessor :name
    alias :to_s :name
    
    # Human readable description.  Use two newlines to break paragraphs.
    attr_accessor :description
    
    # Metric objects that will be used in this widget
    attr_accessor :metrics
    attr_accessor :id
    attr_accessor :options

    # Sets or returns description. For example
    #   widget "Yawns/sec" do
    #     description "Most boring widget ever"
    #   end
    #
    #   puts "Just defined: " + widget(:boring).description
    def description(text = nil)
      @description = text if text
      @description
    end
    
    def name(text = nil)
      @name = text if text
      @name
    end
    
    def id
      @widget_id
    end
    
    def stack(value = nil)
      @options[:stack] = value if value
      @options[:stack]
    end
    
    def numerator(metric_id)
      @options[:numerator] = Vanity.playground.metric(metric_id.to_sym)
    end

    def denominator(metric_id)
      @options[:denominator] = Vanity.playground.metric(metric_id.to_sym)
    end
    
    def rate_data
      return @rate_values if @rate_values
      @rate_values = {}
      
      Vanity::Metric.data(@options[:numerator]).each do |date, value|
        @rate_values[date] = value
      end
      Vanity::Metric.data(@options[:denominator]).each do |date, value|
        @rate_values[date] = value > 0 ? (@rate_values[date].to_f / value.to_f) : 0
        @rate_values[date] *= 100 if @options[:as_percentages]
      end
      
      @rate_values
    end
    
    def graph(*args)
      args.each { |arg| @options[arg] = true }
      stack true if args.include?(:as_percentages)
    end

    def metrics(*metric_ids)
      if metric_ids.any?
        @metrics = {}
        metric_ids.each do |id|
          @metrics[id] = { :metric  => Vanity.playground.metric(id.to_sym),
                           :options => { :y_axis => 1 } }
        end
      end
      @metrics
    end
    
    def add_metric(id, options = {})
      @metrics ||= {}
      @metrics[id] =  { :metric  => Vanity.playground.metric(id.to_sym),
                       :options => { :y_axis => 1 }.merge(options) }
    end
    
    def update_or_create_metric(id, options = {})
      if metrics.try(:has_key?, id)
        metrics[id][:options].merge!(options)
      else
        add_metric(id, options)
      end
    end
    
    # Accepts:
    # args = *metric_ids (assumes y_axis = 1)
    # args { 1 => [metric_ids], 2 => [metric_ids] }
    def y_axis(*args)
      if args.first.is_a? Hash
        args.first.each do |axis, metric_ids|
          metric_ids.each { |metric_id| update_or_create_metric(metric_id, :y_axis => axis) }
        end
      elsif args.first.is_a? Array and args.any?
        metrics(args)
      else
        fail "Incorrect format passed to Widget.y_axis. Looking for { 1 => [metric_id], 2 => [metric_id] }"
      end
    end
  end
end
