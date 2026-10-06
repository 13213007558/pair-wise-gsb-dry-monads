# frozen_string_literal: true

module Dry
  module Monads
    # Selective combinators.
    #
    # A selective value carries an encoded choice and an optional alternative.
    # Unlike monadic bind, the alternative can be inspected before the
    # selector is evaluated. Unlike applicative apply, it is never evaluated
    # when the selected value is already available.
    module Selective
      # Selects an existing value or applies an alternative.
      #
      # A block is called only for the left/alternative branch. The block must
      # return another context of the same selective type.
      #
      # @param alternative [Object, Undefined]
      # @yieldparam value [Object]
      # @return [Object]
      def select(alternative = Undefined, &block)
        bind do |choice|
          unless choice.is_a?(Result)
            raise TypeError, "Expected Result, got #{choice.inspect}"
          end

          if choice.success?
            self.class.pure(choice.success)
          elsif block
            block.(choice.failure)
          elsif Undefined.equal?(alternative)
            raise ArgumentError, "select requires an alternative or a block"
          else
            alternative.fmap { |function| function.call(choice.failure) }
          end
        end
      end

      # Runs one of two effects depending on the encoded choice.
      #
      # @param left [Object] A context wrapping a callable for Failure values
      # @param right [Object] A context wrapping a callable for Success values
      # @return [Object]
      def branch(left, right)
        bind do |choice|
          case choice
          when Result::Success
            right.fmap { |function| function.call(choice.success) }
          when Result::Failure
            left.fmap { |function| function.call(choice.failure) }
          else
            raise TypeError, "Expected Result, got #{choice.inspect}"
          end
        end
      end
    end
  end
end
