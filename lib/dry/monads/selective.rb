# frozen_string_literal: true

module Dry
  module Monads
    # Selective combinators.
    #
    # Selective applicative functors sit between applicative functors and
    # monads. They can inspect a wrapped boolean and choose one branch without
    # the full power of monadic bind.
    module Selective
      extend self

      class << self
        # Chooses between two effectful values.
        #
        # @param condition [Object] Selective value wrapping a Boolean
        # @param if_true [Object] Branch selected for a true condition
        # @param if_false [Object] Branch selected for a false condition
        # @return [Object]
        def branch(condition, if_true, if_false)
          if condition.monad.equal?(Result)
            condition.fmap { |enabled| enabled ? if_true.value! : if_false.value! }
          else
            task_branch(condition, if_true, if_false)
          end
        end

        private

        def task_branch(condition, if_true, if_false)
          selected = condition.bind { |enabled| enabled ? if_true : if_false }
          selected.with_selective_branches([if_true, if_false])
        end
      end
    end
  end
end
