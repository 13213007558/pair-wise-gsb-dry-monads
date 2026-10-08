# frozen_string_literal: true

RSpec.describe(Dry::Monads::Measure) do
  subject(:measure) { described_class[a: Rational(1, 2), b: Rational(1, 3)] }

  let(:empty_measure) { described_class[] }

  it_behaves_like "a monad"

  describe ".[]" do
    it "builds a measure from a hash of rational weights" do
      expect(described_class[a: 1r, b: Rational(1, 2)])
        .to eql(described_class.new(a: 1r, b: Rational(1, 2)))
    end

    it "accepts outcome/weight pairs" do
      expect(described_class[[[:a, 1], [:b, Rational(1, 2)]]])
        .to eql(described_class.new(a: 1r, b: Rational(1, 2)))
    end

    it "merges duplicate outcomes at construction" do
      expect(described_class[[[:a, 1], [:a, 2]]])
        .to eql(described_class.new(a: 3r))
    end

    it "drops zero-weight outcomes" do
      expect(described_class.new(a: 0r, b: 1r)).to eql(described_class.new(b: 1r))
    end

    it "treats absent outcomes as zero weight" do
      expect(measure.weight(:missing)).to eql(0r)
    end

    it "rejects non-rational weights" do
      expect { described_class.new(a: 0.5) }
        .to raise_error(TypeError, "Measure weights must be Integer or Rational, got 0.5")
    end

    it "rejects negative weights" do
      expect { described_class.new(a: -Rational(1, 2)) }
        .to raise_error(ArgumentError, "Measure weights cannot be negative")
    end
  end

  describe ".pure" do
    it "assigns full mass to one outcome" do
      expect(described_class.pure(:a)).to eql(described_class.new(a: 1r))
    end
  end

  describe "::Mixin" do
    subject(:context) { Class.new { include Dry::Monads[:measure] }.new }

    it "adds a Measure constructor" do
      expect(context.Measure(a: Rational(1, 2)))
        .to eql(described_class.new(a: Rational(1, 2)))
    end
  end

  describe "#mass" do
    it "returns the exact unnormalized total mass" do
      expect(measure.mass).to eql(Rational(5, 6))
      expect(measure.evidence).to eql(Rational(5, 6))
      expect(measure.total).to eql(Rational(5, 6))
    end

    it "is zero for an empty measure" do
      expect(empty_measure.mass).to eql(0r)
      expect(empty_measure).to be_empty
    end
  end

  describe "#fmap" do
    it "transforms outcomes while preserving weights" do
      expect(measure.fmap(&:to_s))
        .to eql(described_class.new("a" => Rational(1, 2), "b" => Rational(1, 3)))
    end

    it "merges weights of equal mapped outcomes" do
      expect(measure.fmap { :same }).to eql(described_class.new(same: Rational(5, 6)))
    end

    it "accepts a callable and aliases map" do
      uppercase = :upcase.to_proc

      expect(measure.fmap(uppercase)).to eql(measure.map { |value| value.to_s.upcase.to_sym })
    end
  end

  describe "#bind" do
    let(:source) { described_class.new(a: Rational(1, 4), b: Rational(3, 4)) }

    it "multiplies branch weights and aggregates equal outcomes" do
      result = source.bind do |outcome|
        case outcome
        when :a then described_class.new(x: Rational(1, 2), y: Rational(1, 2))
        when :b then described_class.new(x: Rational(1, 3), y: Rational(2, 3))
        end
      end

      expect(result).to eql(described_class.new(x: Rational(3, 8), y: Rational(5, 8)))
    end

    it "preserves branch mass loss without normalizing" do
      result = source.bind do |outcome|
        case outcome
        when :a then described_class.new(x: Rational(1, 2))
        when :b then described_class.new(x: Rational(1, 4), y: Rational(1, 4))
        end
      end

      expect(result).to eql(described_class.new(x: Rational(5, 16), y: Rational(3, 16)))
      expect(result.mass).to eql(Rational(1, 2))
    end

    it "accepts hashes returned by the continuation" do
      result = source.bind { |_| { x: Rational(1, 2) } }

      expect(result).to eql(described_class.new(x: Rational(1, 2)))
    end

    it "satisfies left identity" do
      continuation = ->(value) do
        described_class.new(value => Rational(1, 2), kept: Rational(1, 2))
      end

      expect(described_class.pure(:a).bind(&continuation)).to eql(continuation.(:a))
    end

    it "satisfies right identity" do
      expect(source.bind { |value| described_class.pure(value) }).to eql(source)
    end

    it "satisfies associativity with unnormalized branches" do
      first = ->(value) do
        case value
        when :a then described_class.new(x: Rational(1, 2), dropped: Rational(1, 2))
        when :b then described_class.new(x: Rational(1, 4))
        end
      end
      second = ->(value) { described_class.new(value => Rational(1, 3), final: Rational(1, 3)) }

      left_to_right = source.bind(&first).bind(&second)
      right_to_left = source.bind { |value| first.(value).bind(&second) }

      expect(left_to_right).to eql(right_to_left)
      expect(left_to_right).to eql(
        described_class.new(
          x: Rational(5, 48),
          final: Rational(7, 48),
          dropped: Rational(1, 24)
        )
      )
    end
  end

  describe "#filter" do
    subject(:measure) do
      described_class.new(
        a: Rational(1, 2),
        b: Rational(1, 3),
        c: Rational(1, 6)
      )
    end

    it "keeps the surviving mass unnormalized" do
      expect(measure.filter { |value| %i[a c].include?(value) })
        .to eql(described_class.new(a: Rational(1, 2), c: Rational(1, 6)))
    end

    it "returns the evidence mass of an event" do
      accepted = ->(value) { %i[a c].include?(value) }

      expect(measure.evidence(&accepted)).to eql(Rational(2, 3))
      expect(measure.filter(&accepted).mass).to eql(Rational(2, 3))
    end

    it "lets the caller explicitly condition on an event" do
      conditional = measure.filter { |value| %i[a c].include?(value) }.normalize

      expect(conditional).to eql(described_class.new(a: Rational(3, 4), c: Rational(1, 4)))
      expect(conditional.mass).to eql(1r)
    end
  end

  describe "#normalize" do
    it "scales every weight by the current total mass" do
      expect(measure.normalize)
        .to eql(described_class.new(a: Rational(3, 5), b: Rational(2, 5)))
      expect(measure.normalize).to be_normalized
    end

    it "does not change the original measure" do
      measure.normalize

      expect(measure).to eql(described_class[a: Rational(1, 2), b: Rational(1, 3)])
    end

    it "refuses to invent a distribution when evidence is zero" do
      expect { empty_measure.normalize }
        .to raise_error(ZeroDivisionError, "Cannot normalize a zero-mass Measure")
    end
  end

  describe "two-layer branching" do
    let(:channels) { described_class.new(mobile: Rational(1, 2), web: Rational(1, 2)) }

    let(:mobile_branches) do
      described_class.new(premium: Rational(3, 4), standard: Rational(1, 4))
    end

    let(:web_branches) do
      described_class.new(
        premium: Rational(1, 4),
        standard: Rational(1, 4),
        rejected: Rational(1, 2)
      )
    end

    let(:branches) do
      lambda do |channel|
        channel == :mobile ? mobile_branches : web_branches
      end
    end

    let(:accepted?) { ->(outcome) { outcome != :rejected } }

    it "matches the hand-expanded joint distribution before conditioning" do
      joint = channels.bind(&branches)

      expect(joint).to eql(
        described_class.new(
          premium: Rational(1, 2),
          standard: Rational(1, 4),
          rejected: Rational(1, 4)
        )
      )
    end

    it "conditions once at the end using all retained evidence" do
      accepted = channels.bind(&branches).filter(&accepted?)

      expect(accepted.evidence).to eql(Rational(3, 4))
      expect(accepted.normalize).to eql(
        described_class.new(premium: Rational(2, 3), standard: Rational(1, 3))
      )
    end

    it "changes the answer when each layer conditions away its own missing mass" do
      conditional_channels = channels.bind do |channel|
        branches.(channel).filter(&accepted?).normalize
      end

      expect(conditional_channels).to eql(
        described_class.new(premium: Rational(5, 8), standard: Rational(3, 8))
      )
    end
  end

  describe "#inspect" do
    it "uses exact rational weights" do
      expect(measure.inspect).to eql("Measure[:a=>1/2, :b=>1/3]")
    end
  end
end
