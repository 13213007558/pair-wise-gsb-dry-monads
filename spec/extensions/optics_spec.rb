# frozen_string_literal: true

Dry::Monads.load_extensions(:optics)

RSpec.describe Dry::Monads::Optics do
  include Dry::Monads[:maybe, :result]

  subject(:optics) { Dry::Monads::Optics }

  describe "lens laws" do
    let(:lens) { optics.key(:name) }
    let(:object) { {name: "Jane", age: 30} }

    it "get-put: setting what you view changes nothing" do
      expect(lens.set(object, lens.view(object))).to eq(object)
    end

    it "put-get: you view what you set" do
      expect(lens.view(lens.set(object, "Jade"))).to eq("Jade")
    end

    it "put-put: the last set wins" do
      expect(lens.set(lens.set(object, "Jade"), "Jo")).to eq(lens.set(object, "Jo"))
    end

    it "does not mutate the input" do
      lens.set(object, "Jade")
      expect(object).to eq(name: "Jane", age: 30)
    end
  end

  describe "composed lens laws" do
    let(:lens) { optics.key(:meta) >> optics.key(:tags) }
    let(:object) { {meta: {tags: %w[a b]}, id: 1} }

    it "composes lenses into a lens" do
      expect(lens).to be_a(Dry::Monads::Optics::Lens)
      expect(lens.view(object)).to eq(%w[a b])
    end

    it "get-put" do
      expect(lens.set(object, lens.view(object))).to eq(object)
    end

    it "put-get" do
      expect(lens.view(lens.set(object, %w[c]))).to eq(%w[c])
    end

    it "put-put" do
      expect(lens.set(lens.set(object, %w[c]), %w[d])).to eq(lens.set(object, %w[d]))
    end

    it "updates only the focus" do
      expect(lens.set(object, %w[c])).to eq(meta: {tags: %w[c]}, id: 1)
    end
  end

  describe "prism laws" do
    let(:prism) { optics.some }

    it "review-preview: previewing a rebuilt whole yields the focus" do
      expect(prism.preview(Some(3))).to eq(Some(3))
    end

    it "does not call the update function on a non-match" do
      called = false
      expect(prism.over(None()) { called = true }).to be_none
      expect(called).to be(false)
    end

    it "returns a non-matching whole unchanged from set" do
      none = None()
      expect(prism.set(none, 5)).to be(none)
    end

    it "maps the focus on a match" do
      expect(prism.over(Some(3)) { |n| n + 1 }).to eq(Some(4))
    end
  end

  describe "missing structure" do
    it "previews a missing key as None" do
      expect(optics.key(:missing).preview({})).to be_none
    end

    it "previews an out-of-bounds index as None" do
      expect(optics.index(5).preview([1, 2])).to be_none
    end

    it "does not call the update function for an out-of-bounds index" do
      called = false
      expect(optics.index(5).over([1, 2]) { called = true }).to eq([1, 2])
      expect(called).to be(false)
    end
  end

  describe "nil focus" do
    it "previews nil as None, following Maybe semantics" do
      expect(optics.key(:name).preview({name: nil})).to be_none
    end

    it "raises when rebuilding through Some, following Some semantics" do
      expect { optics.some.set(Some(1), nil) }.to raise_error(ArgumentError)
    end

    it "rebuilds nil as None when the constructor is Maybe.coerce" do
      prism = optics.prism(
        ->(maybe) { maybe.some? ? maybe : None() },
        Dry::Monads::Maybe.method(:coerce)
      )
      expect(prism.set(Some(1), nil)).to be_none
    end

    it "does not call the update function on Success(nil)" do
      called = false
      success_nil = Success(nil)
      expect(optics.success.over(success_nil) { called = true }).to be(success_nil)
      expect(called).to be(false)
    end
  end

  describe "composition order" do
    let(:users) { [{name: "Jane"}, {name: "Jade"}] }

    it "focuses right-to-left through the structure" do
      optic = optics.index(1) >> optics.key(:name)
      expect(optic.preview(users)).to eq(Some("Jade"))
    end

    it "is not commutative" do
      optic = optics.key(:name) >> optics.index(1)
      expect(optic.preview(users)).to be_none
    end

    it "is associative" do
      left = (optics.index(1) >> optics.key(:name)) >> optics.lens(->(s) { s[0] }, ->(s, c) { c + s[1..] })
      right = optics.index(1) >> (optics.key(:name) >> optics.lens(->(s) { s[0] }, ->(s, c) { c + s[1..] }))

      expect(left.preview(users)).to eq(right.preview(users))
      expect(left.over(users, &:upcase)).to eq(right.over(users, &:upcase))
    end

    it "composes backwards with <<" do
      forward = optics.index(1) >> optics.key(:name)
      backward = optics.key(:name) << optics.index(1)

      expect(backward.preview(users)).to eq(forward.preview(users))
      expect(backward.over(users, &:upcase)).to eq(forward.over(users, &:upcase))
    end
  end

  describe "a Result with nested arrays" do
    let(:result) { Success(users: [{name: "Jane"}, {name: "Jade"}]) }
    let(:optic) { optics.success >> optics.key(:users) >> optics.index(1) >> optics.key(:name) }

    it "previews the deeply nested focus" do
      expect(optic.preview(result)).to eq(Some("Jade"))
    end

    it "is not a lens, because prisms are involved" do
      expect(optic).not_to be_a(Dry::Monads::Optics::Lens)
    end

    it "maps the focus, leaving everything else in place" do
      expect(optic.over(result, &:upcase)).to eq(
        Success(users: [{name: "Jane"}, {name: "JADE"}])
      )
    end

    it "sets the focus" do
      expect(optic.set(result, "Jo")).to eq(
        Success(users: [{name: "Jane"}, {name: "Jo"}])
      )
    end

    it "does not mutate the input" do
      optic.over(result, &:upcase)
      optic.set(result, "Jo")
      expect(result).to eq(Success(users: [{name: "Jane"}, {name: "Jade"}]))
    end

    it "previews a Failure as None" do
      expect(optic.preview(Failure(:oops))).to be_none
    end

    it "does not call the update function on a Failure" do
      called = false
      failure = Failure(:oops)
      expect(optic.over(failure) { called = true }).to be(failure)
      expect(called).to be(false)
    end

    it "previews as None when an intermediate key is missing" do
      expect(optic.preview(Success({}))).to be_none
    end
  end

  describe "failure prism" do
    it "focuses the error of a Failure" do
      expect(optics.failure.preview(Failure(:oops))).to eq(Some(:oops))
      expect(optics.failure.over(Failure(:oops)) { |e| :"#{e}!" }.failure).to eq(:"oops!")
    end

    it "does not match a Success" do
      expect(optics.failure.preview(Success(1))).to be_none
    end
  end
end
