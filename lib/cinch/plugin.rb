# TODO more details in "message dropped" debug output
module Cinch
  module Plugin
    include Helpers

    # @attr plugin_name
    module ClassMethods
      # @return [Hash<Symbol<:pre, :post> => Array<Hook>>] All hooks
      attr_reader :hooks

      # @return [Array<Symbol<:message, :channel, :private>>] The list of events to react on
      attr_accessor :reacting_on

      # @return [String, nil] The name of the plugin
      attr_reader :plugin_name

      def plugin_name=(new_name)
        if new_name.nil? && self.name
          @plugin_name = self.name.split("::").last.downcase
        else
          @plugin_name = new_name
        end
      end

      # @return [Array<Matcher>] All matchers
      attr_reader   :matchers

      # @return [Array<Listener>] All listeners
      attr_reader   :listeners

      # @return [Array<Timer>] All timers
      attr_reader   :timers

      # @return [Array<String>] All CTCPs
      attr_reader   :ctcps

      # @return [String, nil] The help message
      attr_accessor :help

      # @return [String, Regexp, Proc] The prefix
      attr_accessor :prefix

      # @return [String, Regexp, Proc] The suffix
      attr_accessor :suffix

      # @return [Array<Symbol>] Required plugin options
      attr_accessor :required_options

      # @attr [String, Regexp, Proc] pattern
      # @attr [Boolean] use_prefix
      # @attr [Boolean] use_suffix
      # @attr [Symbol] method
      # @attr [Symbol] group
      Matcher = Struct.new(:pattern, :use_prefix, :use_suffix, :method, :group, :prefix, :suffix)

      # @attr [Symbol] event
      # @attr [Symbol] method
      Listener = Struct.new(:event, :method)

      # @attr [Number] interval
      # @attr [Symbol] method
      # @attr [Hash] options
      # @attr [Boolean] registered
      Timer = Struct.new(:interval, :options, :registered)

      # @attr [Symbol] type
      # @attr [Array<Symbol>] for
      # @attr [Symbol] method
      Hook = Struct.new(:type, :for, :method)

      # @api private
      def self.extended(by)
        by.instance_exec do
          @matchers  = []
          @ctcps     = []
          @listeners = []
          @timers    = []
          @help      = nil
          @hooks     = Hash.new{|h, k| h[k] = []}
          @prefix    = nil
          @suffix    = nil
          @reacting_on  = :message
          @required_options = []
          self.plugin_name = nil
        end
      end

      # Set options.
      #
      # Available options:
      #
      #   - {#help}
      #   - {#plugin_name}
      #   - {#prefix}
      #   - {#reacting_on}
      #   - {#required_options}
      #   - {#suffix}
      #
      # @overload set(key, value)
      #   @param [Symbol] key The option's name
      #   @param [Object] value
      #   @return [void]
      # @overload set(options)
      #   @param [Hash<Symbol => Object>] options The options, as key => value associations
      #   @return [void]
      #   @example
      #     set(:help   => "the help message",
      #         :prefix => "^")
      # @return [void]
      # @since 2.0.0
      def set(*args)
        case args.size
        when 1
          # {:key => value, ...}
          args.first.each do |key, value|
            self.send("#{key}=", value)
          end
        when 2
          # key, value
          self.send("#{args.first}=", args.last)
        else
          raise ArgumentError # TODO proper error message
        end
      end

      # Set a match pattern.
      #
      # @param [Regexp, String] pattern A pattern
      # @option options [Symbol] :method (:execute) The method to execute
      # @option options [Boolean] :use_prefix (true) If true, the
      #   plugin prefix will automatically be prepended to the
      #   pattern.
      # @option options [Boolean] :use_suffix (true) If true, the
      #   plugin suffix will automatically be appended to the
      #   pattern.
      # @option options [Symbol] :group (nil) The group the match belongs to.
      # @return [void]
      # @todo Document match/listener grouping
      def match(pattern, options = {})
        options = {:use_prefix => true, :use_suffix => true, :method => :execute, :group => nil, :prefix => nil, :suffix => nil}.merge(options)
        @matchers << Matcher.new(pattern, options[:use_prefix], options[:use_suffix], options[:method], options[:group], options[:prefix], options[:suffix])
      end

      # Events to listen to.
      # @overload listen_to(*types, options = {})
      #   @param [String, Symbol, Integer] *types Events to listen to. Available
      #     events are all IRC commands in lowercase as symbols, all numeric
      #     replies, and the following:
      #
      #       - :channel (a channel message)
      #       - :private (a private message)
      #       - :message (both channel and private messages)
      #       - :error   (IRC errors)
      #       - :ctcp    (ctcp requests)
      #       - :action  (actions, aka /me)
      #
      #   @param [Hash] options
      #   @option options [Symbol] :method (:listen) The method to
      #     execute
      #   @return [void]
      def listen_to(*types)
        options = {:method => :listen}
        if types.last.is_a?(Hash)
          options.merge!(types.pop)
        end

        types.each do |type|
          @listeners << Listener.new(type, options[:method])
        end
      end

      # @version 1.1.1
      def ctcp(command)
        @ctcps << command.to_s.upcase
      end

      # Set which kind of messages to react on (i.e. call {#execute})
      # @param [Array<Symbol<:message, :channel, :private>>] events Which events to react on
      # @return [void]
      # @return [Array<Symbol>, void]
      def react_on(*args)
        self.reacting_on = args.first
      end

      # @example
      #   timer 5, method: :some_method
      #   def some_method
      #     Channel("#cinch-bots").send(Time.now.to_s)
      #   end
      #
      # @param [Number] interval Interval in seconds
      # @option options [Symbol] :method (:timer) Method to call (only if no proc is provided)
      # @option options [Boolean] :threaded (true) Call method in a thread?
      # @return [void]
      # @since 1.1.0
      def timer(interval, options = {})
        options = {:method => :timer, :threaded => true}.merge(options)
        @timers << Timer.new(interval, options, false)
      end

      # Defines a hook which will be run before or after a handler is
      # executed, depending on the value of `type`.
      #
      # @param [Symbol<:pre, :post>] type Run the hook before or after
      #   a handler?
      # @option options [Array<:match, :listen_to, :ctcp>] :for ([:match, :listen_to, :ctcp])
      #   Which kinds of events to run the hook for.
      # @option options [Symbol] :method (true) The method to execute.
      # @return [void]
      # @since 1.1.0
      def hook(type, options = {})
        options = {:for => [:match, :listen_to, :ctcp], :method => :hook}.merge(options)
        __hooks(type) << Hook.new(type, options[:for], options[:method])
      end

      # @return [Hash]
      # @api private
      def __hooks(type = nil, events = nil)
        if type.nil?
          hooks = @hooks
        else
          hooks = @hooks[type]
        end

        if events.nil?
          return hooks
        else
          events = [*events]
          if hooks.is_a?(Hash)
            hooks = hooks.map { |k, v| v }
          end
          return hooks.select { |hook| (events & hook.for).size > 0 }
        end
      end

      # @return [Boolean] True if processing should continue
      # @api private
      def call_hooks(type, event, instance, args)
        stop = __hooks(type, event).find { |hook|
          # stop after the first hook that returns false
          instance.__send__(hook.method, *args) == false
        }

        !stop
      end

      # @param [Bot] bot
      # @return [Array<Symbol>, nil]
      # @since 2.0.0
      # @api private
      def check_for_missing_options(bot)
        @required_options.select { |option|
          !bot.config.plugins.options[self].has_key?(option)
        }
      end
    end

    def __register_listeners
      self.class.listeners.each do |listener|
        @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Registering listener for type `#{listener.event}`"
        new_handler = Handler.new(@bot, listener.event, Pattern.new(nil, //, nil)) do |message, *args|
          if self.class.call_hooks(:pre, :listen_to, self, [message])
            __send__(listener.method, message, *args)
            self.class.call_hooks(:post, :listen_to, self, [message])
          else
            @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Dropping message due to hook"
          end
        end

        @handlers << new_handler
        @bot.handlers.register(new_handler)
      end
    end
    private :__register_listeners

    def __register_ctcps
      self.class.ctcps.each do |ctcp|
        @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Registering CTCP `#{ctcp}`"
        new_handler = Handler.new(@bot, :ctcp, Pattern.generate(:ctcp, ctcp)) do |message, *args|
          if self.class.call_hooks(:pre, :ctcp, self, [message])
            __send__("ctcp_#{ctcp.downcase}", message, *args)
            self.class.call_hooks(:post, :ctcp, self, [message])
          else
            @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Dropping message due to hook"
          end
        end

        @handlers << new_handler
        @bot.handlers.register(new_handler)
      end
    end
    private :__register_ctcps

    def __register_timers
      @timers = self.class.timers.map {|timer_struct|
        @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Registering timer with interval `#{timer_struct.interval}` for method `#{timer_struct.options[:method]}`"

        block = self.method(timer_struct.options[:method])
        options = timer_struct.options.merge(interval: timer_struct.interval)
        Cinch::Timer.new(@bot, options, &block)
      }
    end
    private :__register_timers

    def __register_matchers
      prefix = self.class.prefix || @bot.config.plugins.prefix
      suffix = self.class.suffix || @bot.config.plugins.suffix

      self.class.matchers.each do |pattern|
        _prefix = pattern.use_prefix ? pattern.prefix || prefix : nil
        _suffix = pattern.use_suffix ? pattern.suffix || suffix : nil

        pattern_to_register = Pattern.new(_prefix, pattern.pattern, _suffix)
        react_on = self.class.reacting_on || :message

        @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Registering executor with pattern `#{pattern_to_register.inspect}`, reacting on `#{react_on}`"

        new_handler = Handler.new(@bot, react_on, pattern_to_register, group: pattern.group) do |message, *args|
          method = method(pattern.method)
          arity = method.arity - 1
          if arity > 0
            args = args[0..arity - 1]
          elsif arity == 0
            args = []
          end
          if self.class.call_hooks(:pre, :match, self, [message])
            method.call(message, *args)
            self.class.call_hooks(:post, :match, self, [message])
          else
            @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Dropping message due to hook"
          end
        end
        @handlers << new_handler
        @bot.handlers.register(new_handler)
      end
    end
    private :__register_matchers

    def __register_help
      prefix = self.class.prefix || @bot.config.plugins.prefix
      suffix = self.class.suffix || @bot.config.plugins.suffix
      if self.class.help
        @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Registering help message"
        help_pattern = Pattern.new(prefix, "help #{self.class.plugin_name}", suffix)
        new_handler = Handler.new(@bot, :message, help_pattern) do |message|
          message.reply(self.class.help)
        end

        @handlers << new_handler
        @bot.handlers.register(new_handler)
      end
    end
    private :__register_help

    # @return [void]
    # @api private
    def __register
      missing = self.class.check_for_missing_options(@bot)
      unless missing.empty?
        @bot.loggers.warn "[plugin] #{self.class.plugin_name}: Could not register plugin because the following options are not set: #{missing.join(", ")}"
        return
      end

      __register_listeners
      __register_matchers
      __register_ctcps
      __register_timers
      __register_help
    end

    # @return [Bot]
    attr_reader :bot

    # @return [Array<Handler>] handlers
    attr_reader :handlers

    # @return [Array<Cinch::Timer>]
    attr_reader :timers

    # @return [Storage] The per-plugin persistent storage
    attr_reader :storage

    # @api private
    def initialize(bot)
      @bot = bot
      @handlers = []
      @timers   = []
      @storage  = bot.config.storage.backend.new(@bot.config.storage, self)
      __register
    end

    # @since 2.0.0
    def unregister
      @bot.loggers.debug "[plugin] #{self.class.plugin_name}: Unloading plugin"
      @timers.each do |timer|
        timer.stop
      end

      handlers.each do |handler|
        handler.stop
        handler.unregister
      end
    end

    # (see Bot#synchronize)
    def synchronize(*args, &block)
      @bot.synchronize(*args, &block)
    end

    # Provides access to plugin-specific options.
    #
    # @return [Hash] A hash of options
    def config
      @bot.config.plugins.options[self.class] || {}
    end

    # @api private
    def self.included(by)
      by.extend ClassMethods
    end
  end
end
