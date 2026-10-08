# frozen_string_literal: true

module Dry
  module Monads
    # DelimitedContinuation provides the reset/shift pair of operators for
    # delimited continuations. A computation running inside +reset+ can, at
    # any point, hand "what to do next" over to a +shift+ handler. The
    # handler receives the rest of the computation (up to the nearest
    # enclosing +reset+) as a continuation and decides whether to resume it
    # with a value or to return a value right away, aborting the remaining
    # computation.
    #
    # Continuations are single-shot: every captured continuation can be
    # resumed at most once, and only within the dynamic scope of its
    # +reset+ on the thread that created it.
    #
    # @example early exit
    #   DelimitedContinuation.reset do
    #     DelimitedContinuation.shift { |_k| :early_exit }
    #     :never_reached
    #   end # => :early_exit
    #
    # @example requesting a value from the outside and resuming
    #   DelimitedContinuation.reset do
    #     name = DelimitedContinuation.shift { |k| k.call("Alice") }
    #     "Hello, #{name}!"
    #   end # => "Hello, Alice!"
    #
    # @api public
    class DelimitedContinuation
      # Base class for all DelimitedContinuation errors
      #
      # @api public
      class Error < ::StandardError; end

      # Raised when shift is called where no reset can capture it
      #
      # @api public
      class ShiftOutsideResetError < Error
        def initialize
          super(
            "shift was called outside of its reset: a shift handler can only " +            "capture the continuation of the nearest enclosing reset body"
          )
        end
      end

      # Raised when a continuation is resumed after its reset has finished
      #
      # @api public
      class ContinuationExpiredError < Error
        def initialize
          super(
            "the continuation escaped the dynamic scope of its reset " +            "and can no longer be resumed"
          )
        end
      end

      # Raised when a single-shot continuation is resumed more than once
      #
      # @api public
      class ContinuationAlreadyResumedError < Error
        def initialize
          super("continuations are single-shot: this continuation has already been resumed")
        end
      end

      # Raised when a continuation is used from a thread other than the
      # one that runs its reset
      #
      # @api public
      class CrossThreadResumeError < Error
        def initialize
          super("a continuation can only be captured and resumed on the thread running its reset")
        end
      end

      # Internal control-flow exception used to unwind an abandoned
      # computation so that its ensure blocks still run
      #
      # @api private
      class Unwind < ::Exception; end
      private_constant :Unwind

      # @api private
      STACK_KEY = :dry_monads_delimited_continuation_stack
      private_constant :STACK_KEY

      class << self
        # Delimits a computation. The value of the block is the result,
        # unless a shift handler aborts it or the block raises.
        #
        # @return [Object]
        #
        # @api public
        def reset(&block)
          raise ::ArgumentError, "reset requires a block" if block.nil?

          prompt = new
          stack = current_stack
          stack.push(prompt)
          begin
            prompt.run(&block)
          ensure
            stack.pop
          end
        end

        # Captures the continuation up to the nearest enclosing reset and
        # hands it to the handler. If the handler resumes the continuation
        # with +k.call(value)+, +value+ becomes the result of the shift
        # expression inside the reset body and the final result of reset is
        # the final value of the resumed computation. If the handler returns
        # without resuming, its return value becomes the result of reset.
        #
        # @yieldparam k [#call] single-shot continuation
        # @return [Object]
        #
        # @api public
        def shift(&handler)
          raise ::ArgumentError, "shift requires a block" if handler.nil?

          prompt = current_stack.last
          raise ShiftOutsideResetError if prompt.nil?

          prompt.capture(&handler)
        end

        private

        # @api private
        def current_stack
          stack = ::Thread.current.thread_variable_get(STACK_KEY)
          return stack if stack

          [].tap { |s| ::Thread.current.thread_variable_set(STACK_KEY, s) }
        end
      end

      # @api private
      def run
        @thread = ::Thread.current
        @fiber = ::Fiber.new { yield }
        @active = true
        begin
          drive(@fiber.resume)
        ensure
          @active = false
        end
      end

      # @api private
      def capture(&handler)
        ensure_current_thread!
        raise ShiftOutsideResetError unless ::Fiber.current.equal?(@fiber)

        ::Fiber.yield(handler)
      end

      private

      # @api private
      def drive(value)
        return value unless @fiber.alive?

        handler = value
        resumed = false
        final = nil

        continuation = lambda do |v|
          ensure_current_thread!
          raise ContinuationAlreadyResumedError if resumed
          raise ContinuationExpiredError unless @active

          resumed = true
          final = drive(@fiber.resume(v))
        end

        handler_value =
          begin
            handler.call(continuation)
          rescue ::Exception
            unwind
            raise
          end

        if resumed
          final
        else
          unwind
          handler_value
        end
      end

      # Unwinds the suspended computation so that ensure blocks inside the
      # reset body run even when the continuation is abandoned
      #
      # @api private
      def unwind
        @fiber.raise(Unwind) if @fiber.alive?
      rescue Unwind
        nil
      end

      # @api private
      def ensure_current_thread!
        raise CrossThreadResumeError unless ::Thread.current.equal?(@thread)
      end
    end
  end
end
