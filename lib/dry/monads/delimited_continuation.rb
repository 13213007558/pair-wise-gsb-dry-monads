# frozen_string_literal: true

module Dry
  module Monads
    # DelimitedContinuation provides the reset/shift operators for programming
    # with delimited continuations. A computation running under {.reset} can,
    # at any point, hand "what to do next" over to a {.shift} handler. The
    # handler then decides whether to resume the suspended computation with a
    # value or to return right away, aborting the rest of the computation.
    #
    # Continuations are **one-shot**: a captured continuation can be resumed
    # exactly once, only from the thread that runs the reset block, and only
    # while that reset block is still active.
    #
    # The two possible outcomes of reset are distinct:
    #
    # - if the handler resumes the continuation, reset evaluates to the final
    #   value of the resumed computation (the handler's own return value is
    #   discarded);
    # - if the handler returns without resuming, reset evaluates to the
    #   handler's return value.
    #
    # @example Early exit
    #   result = Dry::Monads::DelimitedContinuation.reset do
    #     Dry::Monads::DelimitedContinuation.shift { |_k| :early_exit }
    #     :never_reached
    #   end
    #   result # => :early_exit
    #
    # @example Requesting a value from the outside world, then resuming
    #   greeting = Dry::Monads::DelimitedContinuation.reset do
    #     name = Dry::Monads::DelimitedContinuation.shift { |k| k.call(fetch_user_name) }
    #     "Hello, #{name}!"
    #   end
    #
    # @api public
    class DelimitedContinuation
      # Base class for all DelimitedContinuation errors
      #
      # @api public
      class Error < ::StandardError; end

      # Raised when shift is called without a dynamically enclosing reset
      #
      # @api public
      class UnboundShiftError < Error; end

      # Raised when a one-shot continuation is resumed more than once
      #
      # @api public
      class ContinuationUsedError < Error; end

      # Raised when a continuation is resumed after its reset block
      # has already finished, i.e. the continuation escaped its scope
      #
      # @api public
      class ContinuationExpiredError < Error; end

      # Raised when a continuation is resumed from a thread other than
      # the one running the reset block
      #
      # @api public
      class CrossThreadContinuationError < Error; end

      # Internal unwind signal used to run ensure clauses when a handler
      # aborts the rest of the computation. Inherits from Exception so
      # that user-level rescue clauses don't swallow it.
      #
      # @api private
      class AbortUnwind < ::Exception; end
      private_constant :AbortUnwind

      # @api private
      ABORT = ::Object.new.freeze
      private_constant :ABORT

      # @api private
      FRAMES_KEY = :dry_monads_delimited_continuation_frames
      private_constant :FRAMES_KEY

      class << self
        # Delimits a computation. The block runs immediately; any shift
        # inside it is handled as described above. Nested resets are
        # independent: a shift is always captured by the nearest
        # dynamically enclosing reset.
        #
        # @param block [Proc] the delimited computation
        # @return [Object] the final value of the computation, or the
        #   shift handler's return value when it aborts
        #
        # @api public
        def reset(&block)
          frame = Frame.new(block)
          frames.push(frame)

          begin
            frame.start
          ensure
            frames.pop
            frame.expire!
          end
        end

        # Captures the continuation up to the nearest enclosing reset and
        # hands it to the handler. The handler receives a one-shot
        # continuation k: calling k(value) resumes the suspended
        # computation, making the shift expression evaluate to value, and
        # k itself returns the final value of the whole computation.
        #
        # @param block [Proc] the handler, called with the continuation
        # @return [Object] the value the continuation is resumed with
        #
        # @api public
        def shift(&handler)
          frame = frames.last

          if frame.nil? || !frame.fiber.equal?(::Fiber.current)
            raise UnboundShiftError,
                  "shift must be called from within the nearest enclosing reset block"
          end

          reply = ::Fiber.yield(ShiftRequest.new(handler))
          raise AbortUnwind if ABORT.equal?(reply)

          reply
        end

        private

        # Stack of active reset frames for the current thread
        #
        # @api private
        def frames
          ::Thread.current.thread_variable_get(FRAMES_KEY) ||
            ::Thread.current.thread_variable_set(FRAMES_KEY, [])
        end
      end

      # A one-shot continuation captured by .shift
      #
      # @api private
      class Continuation
        # The final value of the resumed computation
        attr_reader :result

        def initialize(frame)
          @frame = frame
          @invoked = false
          @result = nil
        end

        def invoked? = @invoked

        # Resumes the suspended computation with the given value and
        # returns its final value
        #
        # @param value [Object] the value the shift expression evaluates to
        # @return [Object] the final value of the delimited computation
        def call(value = nil)
          unless ::Thread.current.equal?(@frame.thread)
            raise CrossThreadContinuationError,
                  "a delimited continuation cannot be resumed from a different thread"
          end

          if @invoked
            raise ContinuationUsedError,
                  "one-shot continuations can be resumed only once"
          end

          if @frame.expired? || !@frame.fiber.alive?
            raise ContinuationExpiredError,
                  "the continuation is no longer valid because its reset block has finished"
          end

          @invoked = true
          @result = @frame.resume(value)
        end
      end
      private_constant :Continuation

      # A single active reset: owns the fiber running the reset block and
      # drives it through the shifts it performs
      #
      # @api private
      class Frame
        attr_reader :fiber, :thread

        def initialize(block)
          @thread = ::Thread.current
          @expired = false
          @fiber = ::Fiber.new do
            block.call
          rescue AbortUnwind
            nil
          end
        end

        def expired? = @expired

        def expire!
          @expired = true
        end

        def start
          drive { fiber.resume }
        end

        def resume(value)
          drive { fiber.resume(value) }
        end

        private

        # Runs the fiber until it completes, invoking shift handlers as
        # they arrive
        def drive
          reply = yield

          while fiber.alive?
            continuation = Continuation.new(self)
            outcome = run_handler(reply.handler, continuation)

            return continuation.result if continuation.invoked?

            # The handler returned without resuming: abort the rest of
            # the computation, unwinding ensure clauses, and use the
            # handler's return value as the result
            fiber.resume(ABORT)
            return outcome
          end

          reply
        end

        def run_handler(handler, continuation)
          handler.call(continuation)
        rescue ::Exception
          # Unwind ensure clauses inside the block before propagating
          fiber.resume(ABORT) if fiber.alive?
          raise
        end
      end
      private_constant :Frame

      # Message yielded from the reset fiber to its driver
      #
      # @api private
      ShiftRequest = ::Data.define(:handler)
      private_constant :ShiftRequest
    end
  end
end
