# frozen_string_literal: true

module Dry
  module Monads
    # Finite discrete measure with exact Rational weights.
    #
    # Weights are evidence rather than probabilities: filtering and binding are
    # allowed to leave a total mass different from 1. Conditional probabilities
    # are therefore produced explicitly with {#normalize}. An empty measure has
    # zero evidence and cannot be normalized.
    #
    # Consider two layers: channels each with mass 1/2. Mobile keeps all users,
    # while web rejects half:
    #
    #   channels = Measure[mobile: 1/2r, web: 1/2r]
    #   mobile   = Measure[premium: 3/4r, standard: 1/4r]
    #   web      = Measure[premium: 1/4r, standard: 1/4r, rejected: 1/2r]
    #   joint    = channels.bind { |channel| channel == :mobile ? mobile : web }
    #
    # The joint evidence is premium 1/2, standard 1/4, rejected 1/4. Filtering
    # rejection keeps evidence 3/4, then one final normalization gives premium
    # 2/3 and standard 1/3. Normalizing each second layer independently removes
    # web's rejected 1/4 before the channel weights are combined, which instead
    # gives premium 5/8 and standard 3/8. In other words, early normalization
    # discards the information that web supplied less retained evidence.
    class Measure
      include Dry::Equalizer(:outcomes)
      include Transformer

      class << self
        # Builds a measure from outcome/weight pairs.
        #
        # @example
        #   Measure[a: Rational(1, 2), b: Rational(1, 3)]
        #   Measure[[[:a, 1], [:b, 2]]]
        #
        # @param outcomes [Hash, #each] outcome/weight pairs
        # @param kwargs [Hash] outcome/weight pairs
        # @return [Measure]
        def [](outcomes = EMPTY_HASH, **kwargs)
          new(outcomes.empty? ? kwargs : outcomes)
        end

        # Wraps one value in a measure with full mass.
        #
        # @param value [Object]
        # @return [Measure]
        def pure(value = Undefined, &block)
          new(Undefined.default(value, block) => 1)
        end
      end

      # @return [Hash<Object, Rational>] frozen outcomes and their weights
      attr_reader :outcomes

      # @api private
      def initialize(outcomes = EMPTY_HASH)
        pairs =
          if outcomes.is_a?(::Hash)
            outcomes.to_a
          elsif outcomes.respond_to?(:each_pair)
            outcomes.each_pair.to_a
          elsif outcomes.respond_to?(:each_entry)
            outcomes.each_entry.to_a
          else
            raise TypeError, "Can't coerce #{outcomes.inspect} to Measure"
          end

        merged = pairs.each_with_object({}) do |(outcome, weight), result|
          result[outcome] = result.fetch(outcome, 0) + rational_weight(weight)
        end

        @outcomes = merged.select { |_, weight| !weight.zero? }.freeze
        @mass = @outcomes.values.sum(0r).freeze
        freeze
      end

      # Transforms outcomes and merges weights of equal results.
      #
      # @return [Measure]
      def fmap(callable = Undefined, *args, &block)
        function = Undefined.default(callable, block || IDENTITY)
        mapped = outcomes.each_with_object({}) do |(outcome, weight), result|
          next_outcome = function.(outcome, *args)
          result[next_outcome] = result.fetch(next_outcome, 0) + weight
        end
        self.class.new(mapped)
      end
      alias_method :map, :fmap

      # Multiplies each source weight by every branch weight, then merges
      # equal outcomes. The block must return a Measure or a coercible Hash.
      #
      # @return [Measure]
      def bind(callable = Undefined, *args, &block)
        function = Undefined.default(callable, block)
        combined = outcomes.each_with_object({}) do |(outcome, weight), result|
          coerce(function.(outcome, *args)).outcomes.each do |next_outcome, next_weight|
            result[next_outcome] = result.fetch(next_outcome, 0) + weight * next_weight
          end
        end
        self.class.new(combined)
      end
      alias_method :flat_map, :bind

      # Keeps outcomes accepted by the predicate. Rejected mass is intentionally
      # not redistributed, so the returned measure may be unnormalized.
      #
      # @return [Measure]
      def filter(callable = Undefined, *args, &block)
        predicate = Undefined.default(callable, block || IDENTITY)
        selected = outcomes.select { |outcome, _| predicate.(outcome, *args) }
        self.class.new(selected)
      end
      alias_method :select, :filter

      # Divides all weights by the current total mass.
      #
      # @raise [ZeroDivisionError] if the measure has no mass
      # @return [Measure]
      def normalize
        raise ZeroDivisionError, "Cannot normalize a zero-mass Measure" if mass.zero?

        self.class.new(outcomes.transform_values { |weight| weight / mass })
      end

      # @return [Rational] total evidence mass
      def mass(*args, &block)
        return @mass if args.empty? && !block_given?

        filter(*args, &block).mass
      end
      alias_method :evidence, :mass
      alias_method :total, :mass

      # @return [Boolean] whether the total mass is one
      def normalized? = mass == 1

      # @return [Boolean] whether the measure has no outcomes
      def empty? = outcomes.empty?

      # @return [Integer] number of distinct outcomes
      def size = outcomes.size

      # Iterates over outcome/weight pairs.
      #
      # @return [Enumerator, Array]
      def each(&block)
        return outcomes.each unless block

        outcomes.each(&block)
      end

      # @return [Hash<Object, Rational>]
      def to_h = outcomes.dup

      # @return [Array<Array(Object, Rational)>]
      def to_a = outcomes.to_a

      # @return [Array<Object>]
      def keys = outcomes.keys

      # @return [Array<Rational>]
      def weights = outcomes.values

      # @return [Rational]
      def weight(outcome) = outcomes.fetch(outcome, 0r)

      # @return [Measure]
      def to_monad = self

      # @return [Class]
      def monad = Measure

      # @return [String]
      def inspect
        pairs = outcomes.map { |outcome, weight| "#{outcome.inspect}=>#{weight}" }
        "Measure[#{pairs.join(", ")}]"
      end
      alias_method :to_s, :inspect

      # Pattern matching on outcome/weight pairs.
      #
      # @api private
      def deconstruct = to_a

      # Pattern matching on outcomes and weights.
      #
      # @api private
      def deconstruct_keys(keys)
        return outcomes.deconstruct_keys(keys) if outcomes.respond_to?(:deconstruct_keys)

        outcomes.slice(*keys)
      end

      private

      def rational_weight(weight)
        case weight
        when Integer, Rational
          weight = Rational(weight)
        else
          raise TypeError, "Measure weights must be Integer or Rational, got #{weight.inspect}"
        end

        raise ArgumentError, "Measure weights cannot be negative" if weight.negative?

        weight
      end

      def coerce(value)
        value.is_a?(Measure) ? value : self.class.new(value)
      end

      # Constructors.
      module Mixin
        # @see Measure
        Measure = Measure

        module Constructors
          # @param outcomes [Hash, #each] outcome/weight pairs
          # @return [Measure]
          def Measure(outcomes = Dry::Monads::EMPTY_HASH, **kwargs)
            Measure.new(outcomes.empty? ? kwargs : outcomes)
          end
        end

        include Constructors
      end
    end

    require "dry/monads/registry"
    register_mixin(:measure, Measure::Mixin)
  end
end
