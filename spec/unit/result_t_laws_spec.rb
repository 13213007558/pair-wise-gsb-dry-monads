# frozen_string_literal: true

# Small, dependency-free property checks for the ResultT monad laws.
# Generators are driven by a fixed-seed PRNG so failures are reproducible.
RSpec.describe(Dry::Monads::ResultT, "monad laws") do
  include Dry::Monads[:result, :result_t, :task, :list]

  # Deterministic xorshift generator.
  let(:rng) do
    state = 0x13579BDF
    lambda do
      state ^= (state << 13) & 0xFFFFFFFF
      state ^= (state >> 17)
      state ^= (state << 5) & 0xFFFFFFFF
      state &= 0xFFFFFFFF
      state / 0xFFFFFFFF.to_f
    end
  end

  let(:cases_count) { 60 }

  def small_int(rand_gen)
    (rand_gen.call * 9).to_i - 4
  end

  def maybe_failure(rand_gen)
    if rand_gen.call < 0.35
      Failure([:err, (rand_gen.call * 100).to_i])
    else
      Success(small_int(rand_gen))
    end
  end

  def wait!(value)
    case value
    when Dry::Monads::Task then value.wait.value!
    else value
    end
  end

  shared_examples "ResultT monad laws" do
    it "satisfies the left unit law: pure(a).bind { f } == f.(a)" do
      cases_count.times do |i|
        a = small_int(rng)
        expected = f.(a).run
        actual = builder.pure(a).bind { |x| f.(x) }.run

        expect(wait!(actual)).to(eq(wait!(expected)), "case ##{i}, a=#{a}")
      end
    end

    it "satisfies the right unit law: m.bind { pure } == m" do
      cases_count.times do |i|
        mon = sample_value
        expected = mon.run
        actual = mon.bind { |x| builder.pure(x) }.run

        expect(wait!(actual)).to(eq(wait!(expected)), "case ##{i}")
      end
    end

    it "satisfies associativity" do
      cases_count.times do |i|
        mon = sample_value

        left_side  = mon.bind { |x| f.(x) }.bind { |y| g.(y) }.run
        right_side = mon.bind { |x| f.(x).bind { |y| g.(y) } }.run

        expect(wait!(left_side)).to(eq(wait!(right_side)), "case ##{i}")
      end
    end

    it "is consistent with fmap: m.fmap(h) == m.bind { pure(h.call(x)) }" do
      h = ->(x) { x * 3 }

      cases_count.times do |i|
        mon = sample_value

        mapped = mon.fmap { |x| h.(x) }.run
        bound  = mon.bind { |x| builder.pure(h.(x)) }.run

        expect(wait!(mapped)).to(eq(wait!(bound)), "case ##{i}")
      end
    end
  end

  context "with Task as the outer monad" do
    let(:builder) { ResultT(Dry::Monads::Task) }

    # f and g are total (never raise): Task-raised errors are a separate,
    # non-Failure channel covered by the functional spec.
    let(:f) do
      lambda do |x|
        if x.even?
          builder.failure([:even, x])
        else
          builder.pure(x + 1)
        end
      end
    end
    let(:g) do
      lambda do |x|
        if x > 2
          builder.pure(x * 10)
        else
          builder.failure([:small, x])
        end
      end
    end

    let(:sample_value) do
      builder.lift(Dry::Monads::Task.pure(maybe_failure(rng)))
    end

    include_examples "ResultT monad laws"
  end

  context "with List as the outer monad" do
    let(:builder) { ResultT(Dry::Monads::List) }

    let(:f) do
      lambda do |x|
        results = [Success(x)]
        if x.negative?
          results << Failure([:negated, x])
          results << Success(x.abs)
        end
        builder.lift(Dry::Monads::List.coerce(results, Dry::Monads::Result))
      end
    end
    let(:g) do
      lambda do |x|
        results = [Success(x), Success(x + 1)]
        results << Failure([:too_big, x]) if x > 2
        builder.lift(Dry::Monads::List.coerce(results, Dry::Monads::Result))
      end
    end

    let(:sample_value) do
      values = Array.new(1 + (rng.call * 3).to_i) { maybe_failure(rng) }
      builder.lift(Dry::Monads::List.new(values, Dry::Monads::Result))
    end

    include_examples "ResultT monad laws"
  end
end
