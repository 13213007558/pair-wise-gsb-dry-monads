# frozen_string_literal: true

module Dry
  module Monads
    # Describes a sequence of operations without executing them.
    #
    # @api public
    class Free
      class << self
        # Creates a free program that returns the given value.
        #
        # @overload pure(value)
        #   @param value [Object]
        #   @return [Free]
        #
        # @overload pure(&block)
        #   @param block [Proc]
        #   @return [Free]
        #
        def pure(value = Undefined, &block)
          Pure.new(Undefined.default(value, block))
        end

        # Creates a suspended instruction.
        #
        # @overload suspend(instruction)
        #   @param instruction [Object]
        #   @return [Free]
        #
        # @overload suspend(&block)
        #   @param block [Proc]
        #   @return [Free]
        #
        def suspend(instruction = Undefined, &block)
          Suspend.new(Undefined.default(instruction, block))
        end
      end

      # Returns self.
      #
      # @return [Free]
      def to_monad = self

      # Returns the Free monad.
      #
      # @return [Class]
      def monad = Free

      # Appends a program-building continuation.
      #
      # @param continuation [#call]
      # @param block [Proc]
      # @return [Free]
      def bind(continuation = Undefined, &block)
        Bind.new(self, Undefined.default(continuation, block))
      end

      # Appends a value-transforming continuation.
      #
      # @param block [Proc]
      # @return [Free]
      def map(&block)
        bind { |value| Free.pure(block.(value)) }
      end

      # Interprets the program in the target monad.
      #
      # @param target [Class, Module]
      # @param transform [#call]
      # @param block [Proc]
      # @return [Object]
      def fold_map(target, transform = Undefined, &block)
        transform = Undefined.default(transform, block)
        return fold_task(transform) if target.equal?(Task)

        fold(target, transform, [], self)
      end

      # @api private
      class Pure < Free
        attr_reader :value

        def initialize(value)
          super()
          @value = value
        end

        def to_s = "Free::Pure(#{value.inspect})"
        alias_method :inspect, :to_s
      end

      # @api private
      class Suspend < Free
        attr_reader :instruction

        def initialize(instruction)
          super()
          @instruction = instruction
        end

        def to_s = "Free::Suspend(#{instruction.inspect})"
        alias_method :inspect, :to_s
      end

      # @api private
      class Bind < Free
        attr_reader :program, :continuation

        def initialize(program, continuation)
          super()
          @program = program
          @continuation = continuation
        end

        def to_s = "Free::Bind(#{program.inspect}, #{continuation.inspect})"
        alias_method :inspect, :to_s
      end

      private

      def fold(target, transform, stack, node)
        loop do
          case node
          when Pure
            return target.pure(node.value) if stack.empty?

            node = stack.pop.(node.value)
          when Suspend
            result = transform.(node.instruction)
            return result if stack.empty?

            return fold_monad(result, transform, stack) unless result.is_a?(Result)

            return result if result.failure?

            node = stack.pop.(result.value!)
          when Bind
            stack.push(node.continuation)
            node = node.program
          else
            raise TypeError, "unexpected free node: #{node.inspect}"
          end
        end
      end

      def fold_monad(result, transform, stack)
        result.bind { |value| continue_monad(result.monad, transform, stack, value) }
      end

      def fold_task(transform)
        Task.new do
          stack = []
          node = self

          loop do
            while node.is_a?(Bind)
              stack.push(node.continuation)
              node = node.program
            end

            case node
            when Pure
              break node.value if stack.empty?

              node = stack.pop.call(node.value)
            when Suspend
              value = transform.(node.instruction).value!
              break value if stack.empty?

              node = stack.pop.call(value)
            else
              raise TypeError, "unexpected free node: #{node.inspect}"
            end
          end
        end
      end

      def continue_monad(target, transform, stack, value)
        return target.pure(value) if stack.empty?

        node = stack.pop.call(value)
        node, stack = unwrap_node(node, stack)

        case node
        when Pure
          continue_monad(target, transform, stack, node.value)
        when Suspend
          result = transform.(node.instruction)
          return result if stack.empty?

          result.bind { |next_value|
            continue_monad(result.monad, transform, stack, next_value)
          }
        else
          raise TypeError, "unexpected free node: #{node.inspect}"
        end
      end

      def unwrap_node(node, stack)
        while node.is_a?(Bind)
          stack = stack + [node.continuation]
          node = node.program
        end

        [node, stack]
      end

      # Free constructors.
      #
      # @api public
      module Mixin
        # @see Free
        Free = Free

        module Constructors
          # Suspends an instruction in a free program.
          #
          # @overload Free(instruction)
          #   @param instruction [Object]
          #   @return [Free]
          #
          # @overload Free(&block)
          #   @param block [Proc]
          #   @return [Free]
          #
          def Free(instruction = Undefined, &block)
            Free.suspend(Undefined.default(instruction, block))
          end
        end

        include Constructors
      end
    end

    require "dry/monads/registry"
    register_mixin(:free, Free::Mixin)
  end
end
