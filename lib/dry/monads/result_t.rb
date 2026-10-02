# frozen_string_literal: true

module Dry
  module Monads
    # ResultT is a monad transformer that stacks Result on top of another
    # ("outer") monad such as Task, List, or Lazy. It lets you compose
    # computations returning +Task<Result>+ or +List<Result>+ without
    # unwrapping both layers by hand at every step, while the semantics
    # of the outer monad are preserved:
    #
    # * Task — an exception raised by the task itself stays on the task's
    #   own error channel (a rejected promise); it is NOT converted to
    #   a Failure. A Failure produced by a normally completed task stays
    #   a plain value inside a fulfilled task.
    # * List — every branch is kept: a Failure in one branch doesn't make
    #   other branches disappear.
    # * Lazy — composing computations neither re-runs the underlying
    #   computation nor forces it.
    #
    # The outer monad is tracked explicitly as a class/module responding
    # to +pure+, it is never inferred from the currently wrapped value.
    #
    # @example chaining Task<Result> computations
    #   ResultT
    #     .lift(Task, Task { 21 })
    #     .bind { |x| ResultT.new(Task, Task.pure(x.odd? ? Failure(:odd) : Success(x))) }
    #     .fmap { |x| x * 2 }
    #     .to_monad # => Task(value=Success(42))
    #
    # @example List<Result> keeps all branches
    #   ResultT
    #     .new(List, List[Success(1), Failure(:e1), Success(3)])
    #     .bind { |x| ResultT.pure(List, x * 10) }
    #     .to_monad # => List[Success(10), Failure(:e1), Success(30)]
    #
    # @api public
    class ResultT
      include Dry::Equalizer(:monad, :value)

      class << self
        # Wraps a value with the outer monad and Success.
        #
        # @overload pure(monad, value)
        #   @param monad [Class] outer monad (Task, List, Lazy, ...)
        #   @param value [Object]
        #   @return [ResultT]
        #
        # @overload pure(monad, &block)
        #   @param monad [Class] outer monad (Task, List, Lazy, ...)
        #   @param block [Proc]
        #   @return [ResultT]
        def pure(monad, value = Undefined, &block)
          new(monad, monad.pure(Result::Success.new(Undefined.default(value, block))))
        end

        # Lifts an outer monad of plain values into ResultT
        # by wrapping every value with Success.
        #
        # @param monad [Class] outer monad (Task, List, Lazy, ...)
        # @param lifted [Object] a value of the outer monad
        # @return [ResultT]
        def lift(monad, lifted)
          new(monad, lifted.fmap { |value| Result::Success.new(value) })
        end
      end

      # The outer monad (a class/module responding to +pure+)
      #
      # @return [Class]
      attr_reader :monad

      # @api private
      attr_reader :value
      protected :value

      # Wraps an outer monad of Result values.
      #
      # @param monad [Class] outer monad (Task, List, Lazy, ...)
      # @param value [Object] outer monad value with Result inside
      def initialize(monad, value)
        unless value.is_a?(monad)
          raise TypeError, "ResultT over #{monad} cannot wrap #{value.inspect}"
        end

        @monad = monad
        @value = value
      end

      # Maps a block over the innermost (successful) value.
      # The outer monad and Failure values are left untouched.
      #
      # @param args [Array<Object>] arguments passed to the block or callable
      # @return [ResultT]
      def fmap(*args)
        if block_given?
          self.class.new(
            monad,
            value.fmap { |result| result.fmap { |x| yield(x, *args) } }
          )
        else
          obj, *rest = args
          fmap { |x| obj.(x, *rest) }
        end
      end
      alias_method :map, :fmap

      # Composes with a computation returning another ResultT over
      # the same outer monad. Short-circuits on Failure: the failure
      # is re-wrapped with the outer monad as is, so for Task it stays
      # a fulfilled value (not a rejection) and for List the branch
      # is kept rather than dropped.
      #
      # @param args [Array<Object>] arguments passed to the block or callable
      # @return [ResultT]
      def bind(*args)
        if block_given?
          self.class.new(
            monad,
            value.bind { |result|
              if result.success?
                coerce(yield(result.value!, *args)).value
              else
                monad.pure(result)
              end
            }
          )
        else
          obj, *rest = args
          bind { |x| obj.(x, *rest) }
        end
      end

      # Returns the raw outer monad value (e.g. +Task<Result>+).
      #
      # @return [Object]
      def to_monad = value

      # @return [String]
      def to_s = "ResultT(#{monad})[#{value.inspect}]"
      alias_method :inspect, :to_s

      private

      # @api private
      def coerce(other)
        unless other.is_a?(ResultT) && other.monad.eql?(monad)
          raise TypeError, "bind must return a ResultT over #{monad}, got: #{other.inspect}"
        end

        other
      end
    end
  end
end
