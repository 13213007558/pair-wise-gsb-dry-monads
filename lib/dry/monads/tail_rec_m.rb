# frozen_string_literal: true

module Dry
  module Monads
    # Stack-safe monadic recursion, commonly known as tailRecM.
    #
    # Result, Maybe, List, and Task provide a `.tail_rec_m` method that
    # repeatedly applies a block to the loop state. Every step the block
    # must return a monadic value wrapping either {Continue} (keep looping
    # with the next state) or {Done} (stop and return the final value).
    # The loop itself is driven by the library so arbitrarily deep
    # recursions don't blow up the Ruby stack.
    #
    # @example
    #   include Dry::Monads[:result]
    #
    #   Result.tail_rec_m(0) do |i|
    #     if i < 100_000
    #       Success(Continue(i + 1))
    #     else
    #       Success(Done(i))
    #     end
    #   end # => Success(100000)
    #
    # @api public
    module TailRecM
      # Instruction to continue the loop with the next state.
      #
      # @api public
      class Continue
        include Dry::Equalizer(:state)

        # @return [Object] the next state of the loop
        attr_reader :state

        # @param state [Object] the next state of the loop
        def initialize(state)
          @state = state
        end

        # Pattern matching
        #
        # @api private
        def deconstruct = [state]

        # @return [String]
        def to_s = "Continue(#{state.inspect})"
        alias_method :inspect, :to_s
      end

      # Instruction to stop the loop and return the final value.
      #
      # @api public
      class Done
        include Dry::Equalizer(:value)

        # @return [Object] the final value of the loop
        attr_reader :value

        # @param value [Object] the final value of the loop
        def initialize(value)
          @value = value
        end

        # Pattern matching
        #
        # @api private
        def deconstruct = [value]

        # @return [String]
        def to_s = "Done(#{value.inspect})"
        alias_method :inspect, :to_s
      end

      # @api private
      def self.invalid_instruction!(instruction)
        raise TypeError,
              "tail_rec_m steps must be Continue or Done, got: #{instruction.inspect}"
      end

      # Constructors for loop instructions.
      #
      # @api public
      module Constructors
        # Instruction to continue a tail_rec_m loop with the next state
        #
        # @param state [Object] the next state of the loop
        # @return [TailRecM::Continue]
        def Continue(state)
          TailRecM::Continue.new(state)
        end

        # Instruction to stop a tail_rec_m loop with the final value
        #
        # @param value [Object] the final value of the loop
        # @return [TailRecM::Done]
        def Done(value)
          TailRecM::Done.new(value)
        end
      end
    end

    extend TailRecM::Constructors
  end
end
