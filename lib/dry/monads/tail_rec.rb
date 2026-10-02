# frozen_string_literal: true

module Dry
  module Monads
    # Markers used by tail-recursive monadic iteration.
    module TailRec
      # Continues iteration with a new state.
      class Continue
        include Dry::Equalizer(:state)

        attr_reader :state

        def initialize(state)
          @state = state
        end

        def self.[](state) = new(state)

        def deconstruct = [state]

        def inspect = "Continue(#{state.inspect})"
        alias_method :to_s, :inspect
      end

      # Ends iteration with the given value.
      class Done
        include Dry::Equalizer(:value)

        attr_reader :value

        def initialize(value)
          @value = value
        end

        def self.[](value) = new(value)

        def deconstruct = [value]

        def inspect = "Done(#{value.inspect})"
        alias_method :to_s, :inspect
      end

      module Constructors
        def Continue(state) = Continue.new(state)

        def Done(value = Undefined, &block)
          Done.new(Undefined.default(value, block))
        end
      end

      extend Constructors

      # Common instance method for eager right-biased monads.
      module Right
        def tail_rec_m(step = nil, &block)
          step ||= block
          raise ArgumentError, "a block or callable is required" unless step.respond_to?(:call)

          TailRec.run_right(value!, step) do |value|
            if monad.equal?(Maybe)
              Maybe.coerce(value)
            else
              self.class.new(value)
            end
          end
        end
      end

      # Common instance method for stopping left-biased monads.
      module Left
        def tail_rec_m(...) = self
      end

      def self.run_right(state, step)
        loop do
          next_monad = step.call(state)
          unless next_monad.respond_to?(:success?)
            raise TypeError, "expected a monadic value, got #{next_monad.inspect}"
          end
          return next_monad unless next_monad.success?

          case marker = next_monad.value!
          when Continue then state = marker.state
          when Done then return yield(marker.value)
          else
            raise TypeError, "expected Continue(state) or Done(value), got #{marker.inspect}"
          end
        end
      end

      def self.run_task_state(state, step)
        run_task_state_marker(Continue.new(state), step)
      end

      def self.run_task(task, step)
        run_task_state_marker(task.value!, step)
      end

      def self.run_task_state_marker(marker, step)
        loop do
          case marker
          when Continue
            next_task = step.call(marker.state)
            unless next_task.respond_to?(:value!)
              raise TypeError, "expected a Task, got #{next_task.inspect}"
            end
            marker = next_task.value!
          when Done
            return marker.value
          else
            raise TypeError,
                  "expected Continue(state) or Done(value), got #{marker.inspect}"
          end
        end
      end

      def self.run_list(states, step)
        frame = Struct.new(:items, :index)
        stack = [frame.new(states.map { Continue.new(_1) }, 0)]
        values = []

        until stack.empty?
          current_frame = stack.last
          if current_frame.index.equal?(current_frame.items.size)
            stack.pop
            next
          end

          marker = current_frame.items[current_frame.index]
          current_frame.index += 1

          case marker
          when Continue
            branch = List.coerce(step.call(marker.state)).value
            stack << frame.new(branch, 0) unless branch.empty?
          when Done
            values << marker.value
          else
            raise TypeError,
                  "expected Continue(state) or Done(value), got #{marker.inspect}"
          end
        end

        List.new(values)
      end
    end

    Continue = TailRec::Continue
    Done = TailRec::Done

    class << self
      def Continue(state) = TailRec.Continue(state)

      def Done(value = Undefined, &block)
        TailRec.Done(value, &block)
      end
    end
  end
end
