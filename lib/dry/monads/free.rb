# frozen_string_literal: true

module Dry
  module Monads
    # Describes a computation as a sequence of abstract instructions.
    #
    # A Free program doesn't perform any effects while it's being built.
    # Effects are performed later by a natural transformation passed to
    # {#fold_map}, and their semantics are determined by the target monad.
    #
    # @api public
    class Free
      class << self
        # Creates a completed Free program.
        #
        # @overload pure(value)
        #   @param value [Object]
        #   @return [Free::Pure]
        #
        # @overload pure(&block)
        #   @param block [Proc]
        #   @return [Free::Pure]
        #
        def pure(value = Undefined, &block)
          Pure.new(Undefined.default(value, block))
        end

        # Suspends a program on an abstract instruction.
        #
        # @param instruction [Object]
        # @return [Free::Suspend]
        def suspend(instruction)
          Suspend.new(instruction)
        end
      end

      # Composes this program with a function returning another Free program.
      #
      # @param continuation [#call]
      # @return [Free::Bind]
      def bind(continuation = Undefined, &block)
        Bind.new(self, Undefined.default(continuation, block))
      end

      # Maps a value produced by this program.
      #
      # @param function [#call]
      # @return [Free::Map]
      def map(function = Undefined, &block)
        Map.new(self, Undefined.default(function, block))
      end
      alias_method :fmap, :map

      # Interprets the program in the given target monad.
      #
      # @param natural [#call] interprets one instruction in the target monad
      # @param target [Result, Task]
      # @return [Result, Task]
      #
      # @example
      #   program.fold_map(Result) { |instruction| Success(instruction.value) }
      #   program.fold_map(->(instruction) { Task { instruction.call } }, Task)
      def fold_map(natural = Undefined, target = Undefined, &block)
        if target_monad?(natural)
          target = natural
          natural = block
        end

        natural = Undefined.default(natural, block)

        if Undefined.equal?(natural)
          raise ArgumentError, "an interpreter must be given"
        end
        unless natural.respond_to?(:call)
          raise TypeError, "interpreter must be callable, got #{natural.inspect}"
        end

        if target.equal?(Result)
          fold_result(natural)
        elsif target.equal?(Task)
          fold_task(natural)
        else
          raise ArgumentError, "target must be Result or Task"
        end
      end

      # @return [Free]
      def to_monad = self

      # @return [Class]
      def monad = Free

      # A completed Free program.
      #
      # @api public
      class Pure < Free
        # @return [Object]
        attr_reader :value

        # @param value [Object]
        def initialize(value)
          super()
          @value = value
        end

        # @return [String]
        def to_s = "Free::Pure(#{value.inspect})"
        alias_method :inspect, :to_s
      end

      # A Free program waiting for an instruction to be interpreted.
      #
      # @api public
      class Suspend < Free
        # @return [Object]
        attr_reader :instruction

        # @param instruction [Object]
        def initialize(instruction)
          super()
          @instruction = instruction
        end

        # @return [String]
        def to_s = "Free::Suspend(#{instruction.inspect})"
        alias_method :inspect, :to_s
      end

      # @abstract
      class Step < Free
        # @return [Free]
        attr_reader :free

        # @return [#call]
        attr_reader :block

        # @param free [Free]
        # @param block [#call]
        def initialize(free, block)
          super()

          unless free.is_a?(Free)
            raise TypeError, "expected Free, got #{free.inspect}"
          end
          unless block.respond_to?(:call)
            raise ArgumentError, "a callable must be given"
          end

          @free = free
          @block = block
        end
      end

      # A monadic bind step.
      #
      # @api public
      class Bind < Step; end

      # A functor map step.
      #
      # @api public
      class Map < Step; end

      # Free constructors.
      #
      # @api public
      module Mixin
        # @see Dry::Monads::Free
        Free = Free

        module Constructors
          # @see Free.suspend
          def Free(instruction)
            Free.suspend(instruction)
          end
        end

        include Constructors
      end

      private

      def unfold(free)
        unless free.is_a?(Free)
          raise TypeError, "expected Free, got #{free.inspect}"
        end

        steps = []

        while free.is_a?(Step)
          steps << [free.class, free.block]
          free = free.free
        end

        unless free.is_a?(Pure) || free.is_a?(Suspend)
          raise TypeError, "expected Free::Pure or Free::Suspend, got #{free.inspect}"
        end

        [steps, free]
      end

      def target_monad?(value)
        value.equal?(Result) || value.equal?(Task)
      end

      def fold_result(natural)
        steps, terminal = unfold(self)
        result = interpret_result_terminal(terminal, natural)

        loop do
          return result if result.failure?
          return result if steps.empty?

          type, block = steps.pop

          if type.equal?(Map)
            result = result.fmap(&block)
          else
            continuation = result.bind(&block)
            next_steps, next_terminal = unfold(continuation)
            steps.concat(next_steps)
            result = interpret_result_terminal(next_terminal, natural)
          end
        end
      end

      def interpret_result_terminal(terminal, natural)
        result =
          case terminal
          when Pure
            Result.pure(terminal.value)
          when Suspend
            natural.call(terminal.instruction)
          end

        unless result.is_a?(Result)
          raise TypeError, "interpreter must return Result, got #{result.inspect}"
        end

        result
      end

      def fold_task(natural)
        promise_class = Task.const_get(:Promise, false)
        result_promise = promise_class.new
        result_promise.send(:state=, :pending)
        result_task = Task.new(result_promise)
        steps, terminal = unfold(self)

        queue = ::Queue.new
        run_task = nil

        fulfill = ->(value) do
          result_promise.send(:complete, true, value, nil)
        end
        reject = ->(error) do
          result_promise.send(:complete, false, nil, error)
        end

        advance = lambda do |current_terminal|
          while current_terminal.is_a?(Pure)
            if steps.empty?
              fulfill.call(current_terminal.value)
              return
            end

            type, block = steps.pop

            if type.equal?(Map)
              current_terminal = Pure.new(block.call(current_terminal.value))
            else
              continuation = block.call(current_terminal.value)
              next_steps, next_terminal = unfold(continuation)
              steps.concat(next_steps)
              current_terminal = next_terminal
            end
          end

          run_task.call(natural.call(current_terminal.instruction))
        end

        run_task = lambda do |task|
          unless task.is_a?(Task)
            reject.call(TypeError.new("interpreter must return Task, got #{task.inspect}"))
            next
          end

          promise = task.send(:promise)
          promise.execute if promise.unscheduled?

          promise.add_observer do |_, value, reason|
            queue << (reason ? [:reject, reason] : [:value, value])
          end
        end
        start_worker = lambda do |current_terminal|
          Thread.new do
            begin
              advance.call(current_terminal)

              until result_promise.complete?
                type, value = queue.pop

                if type.equal?(:reject)
                  reject.call(value)
                  break
                end

                advance.call(Pure.new(value))
              end
            rescue StandardError => error
              reject.call(error)
            end
          end
        end

        if terminal.is_a?(Pure) && steps.empty?
          fulfill.call(terminal.value)
        else
          start_worker.call(terminal)
        end

        result_task
      end
    end

    extend Free::Mixin::Constructors
    Free = Free

    require "dry/monads/registry"
    register_mixin(:free, Free::Mixin)
  end
end
