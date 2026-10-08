# frozen_string_literal: true

RSpec.describe(Dry::Monads::Measure) do
  subject(:measure) { described_class[:a => 1r/3, :b => 2r/3] }

  it_behaves_like "a monad"

  describe ".new" do
    it "accepts exact rational and integer weights" do
      expect(described_class.new([[:a, 1], [:b, 2r/3]]).to_h)
        .to eql(a: 1r, b: 2r/3)
    end

    it "merges duplicate outcomes" do
      expect(described_class.new([[:a, 1r/4], [:a, 1r/2]]).to_h)
        .to eql(a: 3r/4)
    end

    it "omits zero-only outcomes" do
      expect(described_class.new(a: 0r)).to be_empty
    end

    it "rejects floating-point weights" do
      expect { described_class.new(a: 0.25) }
        .to raise_error(TypeError, /integers or rationals/)
    end

    it "rejects negative weights" do
      expect { described_class.new(a: -1r) }
        .to raise_error(ArgumentError, /cannot be negative/)
    end
  end

  describe ".pure" do
    it "wraps a value with unit mass" do
      expect(described_class.pure(:a).to_h).to eql(a: 1r)
    end
  end

  describe ".coerce" do
    it "coerces hashes and pairs" do
      expect(described_class.coerce(a: 1r)).to eql(described_class.new([[:a, 1r]]))
    end

    it "returns an existing measure" do
      expect(described_class.coerce(measure)).to be(measure)
    end
  end

  describe "#fmap" do
    it "merges the weights of equal results" do
      merged = measure.fmap { _1 == :a ? :same : :same }

      expect(merged.to_h).to eql(same: 1r)
      expect(merged.mass).to eql(1r)
    end

    it "preserves unnormalized mass" do
      partial = described_class[:a => 1r/4, :b => 1r/4].fmap { :result }

      expect(partial.to_h).to eql(result: 1r/2)
    end

    it "accepts a callable" do
      callable = -> value { :"#{value}_mapped" }

      expect(measure.fmap(callable)).to eql(measure.fmap(&callable))
    end
  end

  describe "#bind" do
    it "multiplies branch weights and aggregates equal results" do
      bound = measure.bind do |branch|
        case branch
        when :a then described_class[:yes => 1r/2, :no => 1r/2]
        when :b then described_class[:yes => 1r/4, :no => 3r/4]
        end
      end

      expect(bound.to_h).to eql(yes: 1r/3, no: 2r/3)
      expect(bound.mass).to eql(1r)
    end

    it "preserves evidence removed by nested filters" do
      branch = described_class[:ok => 1r/3, :rejected => 2r/3].filter { _1 == :ok }
      bound = described_class[:start => 2r/5].bind { branch }

      expect(bound.to_h).to eql(ok: 2r/15)
      expect(bound.mass).to eql(2r/15)
    end

    it "satisfies the left identity law" do
      f = ->(value) { described_class[value => 1r/4, :other => 3r/4] }

      expect(described_class.pure(:a).bind(&f)).to eql(f.(:a))
    end

    it "satisfies the right identity law" do
      expect(measure.bind { described_class.pure(_1) }).to eql(measure)
    end

    it "satisfies the associativity law" do
      f = ->(value) { described_class[:"#{value}_x" => 1r/3, :other => 2r/3] }
      g = ->(value) { described_class[value => 1r/2, :end => 1r/2] }

      expect(measure.bind(&f).bind(&g))
        .to eql(measure.bind { |value| f.(value).bind(&g) })
    end
  end

  describe "#filter" do
    it "keeps matching branches and the unnormalized total mass" do
      filtered = measure.filter { _1 == :a }

      expect(filtered.to_h).to eql(a: 1r/3)
      expect(filtered.mass).to eql(1r/3)
    end

    it "does not redistribute removed mass" do
      filtered = measure.filter { _1 == :b }

      expect(filtered[:b]).to eql(2r/3)
      expect(filtered).not_to eql(filtered.normalize)
    end
  end

  describe "#evidence" do
    it "returns the retained mass of an event" do
      expect(measure.evidence { _1 == :b }).to eql(2r/3)
    end
  end

  describe "#condition" do
    it "returns a normalized conditional measure and its evidence" do
      conditional, event_mass = measure.condition { _1 == :b }

      expect(event_mass).to eql(2r/3)
      expect(conditional.to_h).to eql(b: 1r)
    end

    it "does not turn a zero-mass event into a fake distribution" do
      expect { measure.condition { false } }
        .to raise_error(ZeroDivisionError, /zero-mass event/)
    end
  end

  describe "#normalize" do
    it "scales an unnormalized measure explicitly" do
      normalized = described_class[:a => 1r/4, :b => 3r/4].normalize

      expect(normalized.to_h).to eql(a: 1r/4, b: 3r/4)
      expect(normalized.mass).to eql(1r)
    end

    it "refuses to normalize zero mass" do
      expect { described_class.new.normalize }
        .to raise_error(ZeroDivisionError, /zero-mass measure/)
    end
  end

  describe "two-layer branches" do
    let(:first_layer) { described_class[:a => 2r/5, :b => 3r/5] }

    let(:branch_a) do
      described_class[[:a, :ok] => 1r/3, [:a, :rejected] => 2r/3]
    end
    let(:branch_b) do
      described_class[[:b, :ok] => 1r/2, [:b, :rejected] => 1r/2]
    end

    def accepted?(event) = event.last == :ok

    it "matches the hand-expanded joint measure" do
      joint = first_layer.bind do |branch|
        continuation = branch == :a ? branch_a : branch_b
        continuation.filter(&method(:accepted?))
      end

      expect(joint.to_h).to eql([:a, :ok] => 2r/15, [:b, :ok] => 3r/10)
      expect(joint.mass).to eql(13r/30)
    end

    it "shows why per-layer normalization differs from one final normalization" do
      per_layer = first_layer.bind do |branch|
        continuation = branch == :a ? branch_a : branch_b
        conditional, = continuation.condition(&method(:accepted?))
        conditional
      end

      final_normalization = first_layer
        .bind { |branch| (branch == :a ? branch_a : branch_b).filter(&method(:accepted?)) }
        .normalize

      expect(per_layer.normalize.to_h).to eql([:a, :ok] => 2r/5, [:b, :ok] => 3r/5)
      expect(final_normalization.to_h).to eql([:a, :ok] => 4r/13, [:b, :ok] => 9r/13)
    end
  end

  describe "#inspect" do
    it "renders exact rational weights" do
      expect(measure.inspect).to eql("Measure[:a=>(1/3), :b=>(2/3)]")
    end
  end
end
