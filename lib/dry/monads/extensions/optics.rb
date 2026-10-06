# frozen_string_literal: true

module Dry
  module Monads
    module Extensions
      # Small composable optics: lenses for product types (hashes, arrays,
      # plain objects) and prisms for sum types (Maybe, Result).
      #
      # All optics are immutable: +set+/+over+ never mutate the given
      # structure, they return an updated copy instead. Missing structure
      # is expressed with the existing Maybe monad: +preview+ returns
      # +None+ when the focus cannot be reached, and +over+ leaves the
      # structure untouched (without calling the update function) when
      # a prism does not match.
      #
      # @example
      #   Dry::Monads.load_extensions(:optics)
      #
      #   optic = Dry::Monads::Extensions::Optics::Prism.success >>
      #     Dry::Monads::Extensions::Optics::Lens.key(:items) >>
      #     Dry::Monads::Extensions::Optics::Lens.index(0)
      #
      #   optic.over(Success({items: [1, 2]}), &:succ) # => Success({items: [2, 2]})
      #   optic.over(Failure(:nope), &:succ)           # => Failure(:nope)
      #
      # @api public
      module Optics
        # Composes two optics into an {Optional}.
        #
        # @param left [#preview, #set]
        # @param right [#preview, #set]
        # @return [Optional]
        #
        # @api private
        def self.compose(left, right)
          Optional.new(
            ->(structure) {
              left.preview(structure).bind { |inner| right.preview(inner) }
            },
            ->(structure, value) {
              left.preview(structure).fmap { |inner|
                left.set(structure, right.set(inner, value))
              }.value_or(structure)
            }
          )
        end

        # A total optic focusing on a single value inside a product type.
        #
        # @api public
        class Lens
          # Focuses on a Hash key. Setting inserts the key when absent.
          #
          # @param key [Object]
          # @return [Lens]
          def self.key(key)
            new(
              ->(structure) { structure[key] },
              ->(structure, value) { structure.merge(key => value) }
            )
          end

          # Focuses on an Array index.
          #
          # @param index [Integer]
          # @return [Lens]
          def self.index(index)
            new(
              ->(structure) { structure[index] },
              ->(structure, value) {
                structure.dup.tap { |copy| copy[index] = value }
              }
            )
          end

          # Focuses on an attribute of a plain object, read with +name+
          # and written with +name=+ on a copy of the object.
          #
          # @param name [Symbol]
          # @return [Lens]
          def self.attr(name)
            new(
              ->(structure) { structure.public_send(name) },
              ->(structure, value) {
                structure.dup.tap { |copy| copy.public_send(:"#{name}=", value) }
              }
            )
          end

          # @param getter [#call] structure -> focus
          # @param setter [#call] (structure, value) -> updated structure
          # @param previewer [#call, nil] optional structure -> Maybe(focus),
          #   used by composed lenses so that missing intermediate structure
          #   yields None instead of raising
          def initialize(getter, setter, previewer = nil)
            super()
            @getter = getter
            @setter = setter
            @previewer = previewer
          end

          # Extracts the focus.
          #
          # @param structure [Object]
          # @return [Object]
          def view(structure) = @getter.call(structure)

          # Extracts the focus, +None+ when it is nil or cannot be reached.
          #
          # @param structure [Object]
          # @return [Maybe]
          def preview(structure)
            if @previewer
              @previewer.call(structure)
            else
              Maybe.coerce(view(structure))
            end
          end

          # Replaces the focus, returning an updated copy.
          #
          # @param structure [Object]
          # @param value [Object]
          # @return [Object]
          def set(structure, value) = @setter.call(structure, value)

          # Maps the focus, returning an updated copy.
          #
          # @param structure [Object]
          # @yieldparam focus [Object]
          # @return [Object]
          def over(structure, &fn) = set(structure, fn.call(view(structure)))

          # Composes with another optic. Lens + Lens stays a Lens,
          # composing with a Prism or Optional yields an Optional.
          #
          # @param other [Lens, Prism, Optional]
          # @return [Lens, Optional]
          def and_then(other)
            if other.is_a?(Lens)
              Lens.new(
                ->(structure) { other.view(view(structure)) },
                ->(structure, value) { set(structure, other.set(view(structure), value)) },
                ->(structure) { preview(structure).bind { |inner| other.preview(inner) } }
              )
            else
              Optics.compose(self, other)
            end
          end
          alias_method :>>, :and_then
        end

        # A partial optic focusing on one case of a sum type.
        #
        # When the structure does not match, +preview+ returns +None+ and
        # +set+/+over+ return the structure unchanged (the update function
        # is not called). Values produced by +over+ are fed to the prism's
        # constructor, so a nil result is handled with the semantics of
        # that constructor (e.g. Some(nil) raises, Success(nil) is fine).
        #
        # @api public
        class Prism
          # Matches Maybe::Some, builds with Some(...).
          #
          # @return [Prism]
          def self.some
            new(
              matcher: ->(structure) {
                structure.is_a?(Maybe::Some) ? structure : Maybe::None.instance
              },
              builder: Maybe::Some.method(:new)
            )
          end

          # Matches Result::Success, builds with Success(...).
          #
          # @return [Prism]
          def self.success
            new(
              matcher: ->(structure) {
                if structure.is_a?(Result::Success)
                  Maybe.coerce(structure.value!)
                else
                  Maybe::None.instance
                end
              },
              builder: Result::Success.method(:new)
            )
          end

          # Matches Result::Failure, builds with Failure(...).
          #
          # @return [Prism]
          def self.failure
            new(
              matcher: ->(structure) {
                if structure.is_a?(Result::Failure)
                  Maybe.coerce(structure.failure)
                else
                  Maybe::None.instance
                end
              },
              builder: Result::Failure.method(:new)
            )
          end

          # @param matcher [#call] structure -> Maybe(focus)
          # @param builder [#call] focus -> structure
          def initialize(matcher:, builder:)
            super()
            @matcher = matcher
            @builder = builder
          end

          # Extracts the focus when the case matches.
          #
          # @param structure [Object]
          # @return [Maybe]
          def preview(structure) = @matcher.call(structure)

          # Builds a structure from a focus value.
          #
          # @param value [Object]
          # @return [Object]
          def review(value) = @builder.call(value)

          # Replaces the focus when the case matches, otherwise returns
          # the structure unchanged.
          #
          # @param structure [Object]
          # @param value [Object]
          # @return [Object]
          def set(structure, value)
            if preview(structure).some?
              review(value)
            else
              structure
            end
          end

          # Maps the focus when the case matches, otherwise returns the
          # structure unchanged without calling the function.
          #
          # @param structure [Object]
          # @yieldparam focus [Object]
          # @return [Object]
          def over(structure, &fn)
            preview(structure).fmap { |focus| review(fn.call(focus)) }.value_or(structure)
          end

          # Composes with another optic. Prism + Prism stays a Prism,
          # composing with a Lens or Optional yields an Optional.
          #
          # @param other [Lens, Prism, Optional]
          # @return [Prism, Optional]
          def and_then(other)
            if other.is_a?(Prism)
              Prism.new(
                matcher: ->(structure) {
                  preview(structure).bind { |inner| other.preview(inner) }
                },
                builder: ->(value) { review(other.review(value)) }
              )
            else
              Optics.compose(self, other)
            end
          end
          alias_method :>>, :and_then
        end

        # A partial optic without a builder, produced by composing a
        # Prism with a Lens (or anything with an Optional).
        #
        # @api public
        class Optional
          # @param preview_fn [#call] structure -> Maybe(focus)
          # @param set_fn [#call] (structure, value) -> structure
          def initialize(preview_fn, set_fn)
            super()
            @preview_fn = preview_fn
            @set_fn = set_fn
          end

          # Extracts the focus when the whole path matches.
          #
          # @param structure [Object]
          # @return [Maybe]
          def preview(structure) = @preview_fn.call(structure)

          # Replaces the focus when the whole path matches, otherwise
          # returns the structure unchanged.
          #
          # @param structure [Object]
          # @param value [Object]
          # @return [Object]
          def set(structure, value) = @set_fn.call(structure, value)

          # Maps the focus when the whole path matches, otherwise returns
          # the structure unchanged without calling the function.
          #
          # @param structure [Object]
          # @yieldparam focus [Object]
          # @return [Object]
          def over(structure, &fn)
            preview(structure).fmap { |focus| set(structure, fn.call(focus)) }.value_or(structure)
          end

          # Composes with another optic.
          #
          # @param other [Lens, Prism, Optional]
          # @return [Optional]
          def and_then(other) = Optics.compose(self, other)
          alias_method :>>, :and_then
        end
      end
    end
  end
end
