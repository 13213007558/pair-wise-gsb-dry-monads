# frozen_string_literal: true

module Dry
  module Monads
    # Finite, unnormalized discrete measure.
    #
    # Weights are exact rational numbers. The measure keeps the total mass of
    # rejected branches until the caller explicitly asks for normalization. This
    # preserves evidence instead of turning a partial branch into a fake
    # probability distribution.
    #
    # @example evidence and conditioning
    #   outcomes = Measure(true => 1r/4, false => 3r/4)
    #   accepted, evidence = outcomes.condition(&:itself)
    #
    #   evidence                    # => (1/4)
    #   accepted                    # => Measure(true => (1/1))
    #   outcomes.filter(&:itself)   # => Measure(true => (1/4))
    #
    # @example nested branches
    #   first = Measure(:a => 2r/5, :b => 3r/5)
    #
    #   # Normalizing every layer separately discards the parent masses:
    #   #   a -> 2/5, b -> 3/5
    #   #
    #   # Leaving both layers unnormalized and normalizing once at the end
    #   # keeps the joint evidence 2/15 and 3/10 (4/13 and 9/13 after
    #   # conditioning on :ok).
    #   joint = first.bind do |branch|
    #     if branch == :a
    #       Measure([:a, :ok] => 1r/3, [:a, :rejected] => 2r/3)
    #         .filter { |_, event| event == :ok }
    #     else
    #       Measure([:b, :ok] => 1r/2, [:b, :rejected] => 1r/2)
    #         .filter { |_, event| event == :ok }
    #     end
    #   end
    #   joint.normalize
    #
    class Measure
      include Dry::Equalizer(:value)

      class << self
        # Builds a measure from a hash or outcome/weight pair collection.
        #
        # @param outcomes [Hash{Object => Numeric}, Array<Array(Object, Numeric)>]
        # @return [Measure]
        def [](outcomes = Undefined)
          new(Undefined.default(outcomes, {}))
        end

        # Coerces a measure, hash, or pair collection to a measure.
        #
        # @param value [Measure, Hash{Object => Numeric}, Array<Array(Object, Numeric)>]
        # @return [Measure]
        def coerce(value)
          return value if value.is_a?(Measure)

          new(value)
        end

        # Wraps one value with unit mass.
        #
        # @param value [Object]
        # @return [Measure]
        def pure(value = Undefined, &block)
          new(Undefined.default(value, block) => 1)
        end
      end

      # Immutable outcome/weight hash in insertion order.
      attr_reader :value
      protected :value

      # @param outcomes [Measure, Hash{Object => Numeric}, Array<Array(Object, Numeric)>]
      def initialize(outcomes = {})
        @value = normalize_pairs(outcomes).freeze
        freeze
      end

      # Transforms outcomes and combines the masses of equal results.
      #
      # @return [Measure]
      def fmap(callable = Undefined, *args, &block)
        callable = Undefined.default(callable, block)
        transformed = value.each_with_object({}) do |(outcome, weight), pairs|
          add_weight(pairs, callable.(outcome, *args), weight)
        end

        self.class.new(transformed)
      end
      alias_method :map, :fmap

      # Multiplies each outer branch weight by the branch measure weights.
      #
      # @return [Measure]
      def bind(callable = Undefined, *args, &block)
        callable = Undefined.default(callable, block)
        bound = value.each_with_object({}) do |(outcome, weight), pairs|
          continuation = self.class.coerce(callable.(outcome, *args))

          continuation.each do |result, branch_weight|
            add_weight(pairs, result, weight * branch_weight)
          end
        end

        self.class.new(bound)
      end
      alias_method :flat_map, :bind

      # Keeps matching outcomes without distributing the removed mass.
      #
      # @return [Measure]
      def filter(callable = Undefined, &block)
        callable = Undefined.default(callable, block || IDENTITY)
        self.class.new(value.select { |outcome, _| callable.(outcome) })
      end
      alias_method :select, :filter

      # Divides every weight by the current total mass.
      #
      # @return [Measure]
      # @raise [ZeroDivisionError] if the measure has zero mass
      def normalize
        raise ZeroDivisionError, "cannot normalize a zero-mass measure" if mass.zero?

        self.class.new(value.transform_values { |weight| weight / mass })
      end

      # Returns the mass retained by the event without normalizing it.
      #
      # @return [Rational]
      def evidence(callable = Undefined, &block)
        filter(callable, &block).mass
      end

      # Returns the normalized conditional measure and its evidence mass.
      #
      # @return [Array(Measure, Rational)]
      # @raise [ZeroDivisionError] if the event has zero mass
      def condition(callable = Undefined, &block)
        conditioned = filter(callable, &block)
        event_mass = conditioned.mass

        if event_mass.zero?
          raise ZeroDivisionError, "cannot condition on a zero-mass event"
        end

        [conditioned.normalize, event_mass]
      end

      # Sums all weights.
      #
      # @return [Rational]
      def mass
        value.each_value.reduce(0r, :+)
      end
      alias_method :total_mass, :mass

      # Returns the weight of one outcome.
      #
      # @return [Rational]
      def weight(outcome) = value.fetch(outcome, 0r)
      alias_method :[], :weight

      # Iterates over outcome/weight pairs.
      #
      # @return [Enumerator]
      def each(&block)
        return value.each unless block

        value.each(&block)
      end

      # @return [Hash{Object => Rational}]
      def to_h = value.dup

      # @return [Array<Array(Object, Rational)>]
      def to_a = value.to_a

      # @return [Array<Array(Object, Rational)>]
      def deconstruct = to_a

      # @return [Integer]
      def size = value.size
      alias_method :length, :size

      # @return [Boolean]
      def empty? = value.empty?

      # @return [Boolean]
      def zero_mass? = mass.zero?

      # @return [Measure]
      def to_monad = self

      # @return [Class]
      def monad = Measure

      # @return [String]
      def inspect
        pairs = value.map { |outcome, weight| "#{outcome.inspect}=>#{weight.inspect}" }.join(", ")
        "Measure[#{pairs}]"
      end
      alias_method :to_s, :inspect

      private

      def normalize_pairs(outcomes)
        case outcomes
        when Measure
          outcomes.value.dup
        when ::Hash, ::Array
          combine_pairs(outcomes)
        else
          raise TypeError, "Can't coerce #{outcomes.inspect} to Measure"
        end
      end

      def combine_pairs(pairs)
        pairs.each_with_object({}) do |(outcome, raw_weight), combined|
          add_weight(combined, outcome, rational_weight(raw_weight))
        end
      end

      def add_weight(pairs, outcome, raw_weight)
        weight = rational_weight(raw_weight)

        if weight.nonzero? || pairs.key?(outcome)
          pairs[outcome] = pairs.fetch(outcome, 0r) + weight
          pairs.delete(outcome) if pairs[outcome].zero?
        end
      end

      def rational_weight(weight)
        case weight
        when ::Integer, ::Rational
          weight = Rational(weight)
          raise ArgumentError, "measure weights cannot be negative" if weight.negative?

          weight
        else
          raise TypeError, "measure weights must be integers or rationals, #{weight.inspect} given"
        end
      end

      module Mixin
        # @see Dry::Monads::Measure
        Measure = Measure

        module Constructors
          # Measure constructor.
          # @return [Measure]
          def Measure(value) = Measure.coerce(value)
        end

        include Constructors
      end
    end

    require "dry/monads/registry"
    register_mixin(:measure, Measure::Mixin)
  end
end
