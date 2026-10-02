# frozen_string_literal: true

module Dry
  module Monads
    # ResultT is the Result (Either) monad transformer. It represents a
    # computation carried by an "outer" monad (e.g. Task or List) whose value
    # is a {Result}. The block passed to {#bind} works with the unwrapped
    # successful value and returns another ResultT; short-circuiting on Failure
    # happens without leaving the outer monad.
    #
    # The outer monad is always carried explicitly, it is never guessed from
    # the current value. Obtain a bound builder with {ResultT.[]}:
    #
    # @example async computations returning Results
    #   AsyncResult = ResultT(Task)
    #
    #   AsyncResult.lift(Task { Success(fetch_user(id)) }).
    #     bind { |user| AsyncResult.lift(Task { save(user) }) }.
    #     run # => Task(Success(saved_user))
    #
    # An exception raised by the Task itself stays on the Task channel
    # (a rejected Task) while a Failure value is carried as a fulfilled
    # Task wrapping a Failure.
    #
    # @api public
    class ResultT
      # A ResultT bound to a concrete outer monad.
      # Returned by {Dry::Monads.ResultT} / {ResultT.[]}.
      #
      # @api public
      class Builder
        # @return [Class, Module] the outer monad (Task, List, ...)
        attr_reader :outer

        # @api private
        def initialize(outer)
          unless outer.respond_to?(:pure)
            raise ArgumentError,
                  "#{outer.inspect} cannot be used as an outer monad for ResultT"
          end

          @outer = outer
        end

        # Lifts an outer-monadic value containing a Result into ResultT.
        #
        # @param outer_value [Object] e.g. Task<Result> or List<Result>
        # @return [ResultT]
        def lift(outer_value) = ResultT.new(outer, outer_value)

        alias_method :call, :lift
        alias_method :[], :lift

        # Lifts a plain value into outer(Success(value)).
        #
        # @param value [Object]
        # @return [ResultT]
        def pure(value = Undefined, &block)
          v = Undefined.default(value, block)
          lift(outer.pure(Result::Success.new(v)))
        end

        # Lifts an error into outer(Failure(error)).
        #
        # @param error [Object]
        # @return [ResultT]
        def failure(error = Undefined, &block)
          e = Undefined.default(error, block)
          lift(outer.pure(Result::Failure.new(e, RightBiased::Left.trace_caller)))
        end

        # @return [Class] the transformer monad
        def monad = ResultT
      end

      class << self
        # Binds the transformer to an outer monad.
        #
        # @param outer [Class, Module] Task, List, ...
        # @return [Builder]
        def [](outer) = Builder.new(outer)
      end

      # @return [Class, Module] the outer monad
      attr_reader :outer

      # @param outer [Class, Module] the outer monad
      # @param value [Object] an outer-monadic value containing Results
      def initialize(outer, value)
        @outer = outer
        @value = normalize(value)
      end

      # Returns the raw outer-monadic value (Task<Result>, List<Result>, ...).
      #
      # @return [Object]
      def run = @value
      alias_method :to_monad, :run

      # Maps a block over the successful inner value while staying in the
      # outer monad. Failure values pass through untouched.
      #
      # @return [ResultT]
      def fmap(callable = Undefined, &block)
        f = Undefined.default(callable, block)

        ResultT.new(
          outer,
          run.fmap { |inner| inner.fmap { |value| f.(value) } }
        )
      end

      # Composes two computations. The block receives the unwrapped successful
      # value and must return another ResultT. A Failure inner value short-
      # circuits the rest of the chain but never leaves the outer monad:
      # for List, other branches keep running; for Task, the promise stays
      # fulfilled and carries the Failure (a raised exception is a different,
      # rejected Task).
      #
      # @return [ResultT]
      def bind(callable = Undefined, &block)
        f = Undefined.default(callable, block)

        ResultT.new(
          outer,
          run.bind do |inner|
            if inner.success?
              f.(inner.value!).run
            else
              outer.pure(inner)
            end
          end
        )
      end

      # @return [String]
      def inspect = "ResultT(#{run.inspect})"
      alias_method :to_s, :inspect

      # @return [Boolean]
      def ==(other)
        equal?(other) ||
          other.is_a?(ResultT) &&
            outer.equal?(other.outer) &&
            run == other.run
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash = [self.class, outer, run].hash

      # @return [Class]
      def monad = ResultT

      private

      # Keeps lifted Lists typed as List<Result> so that values produced by
      # List.pure (untyped) and lifted/coerced values remain structurally equal.
      def normalize(value)
        if outer.equal?(List) && value.is_a?(List)
          List.new(value.to_ary, Result)
        else
          value
        end
      end

      # Constructors.
      #
      # @api public
      module Mixin
        # @see Dry::Monads::ResultT
        ResultT = ResultT

        # Value constructors
        module Constructors
          # Binds ResultT to the given outer monad.
          #
          # @param outer [Class, Module] Task, List, ...
          # @return [ResultT::Builder]
          def ResultT(outer) = ResultT::Builder.new(outer)
        end

        include Constructors
      end
    end

    # @see ResultT::Mixin::Constructors#ResultT
    def self.ResultT(outer) = ResultT::Builder.new(outer)
    extend ResultT::Mixin::Constructors

    require "dry/monads/registry"
    register_mixin(:result_t, ResultT::Mixin)
  end
end
