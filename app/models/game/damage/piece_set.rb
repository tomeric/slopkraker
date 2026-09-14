module Game
  module Damage
    # Which pieces of one object are gone, as a bitset.
    #
    # This is what makes a city's worth of destruction storable. A thousand-piece building
    # is 182 bytes here; as rows it would be a thousand of them, and a thousand buildings a
    # quarter of a million. The column is the reason a piece is not a record.
    #
    # Byte `index / 8`, bit `index % 8`, least significant bit first. The ordering is
    # arbitrary and must never change -- it is what a stored blob means, and every bitset
    # already written down assumes it.
    class PieceSet
      attr_reader :size

      def self.from_blob(blob, size)
        new(size).tap { |set| set.replace(blob) }
      end

      def initialize(size)
        @size = size.to_i
        @bytes = Array.new(byte_length, 0)
      end

      # Short blobs are padded rather than trusted. A stored bitset predates any change to
      # a building's piece count, and a generator that grew a building by one cell should
      # read as "that cell is intact" rather than raise on everyone still in the match.
      def replace(blob)
        bytes = (blob || "").b.bytes
        @bytes = Array.new(byte_length) { |i| bytes[i] || 0 }
      end

      def add(index)
        check!(index)
        return false if include?(index)

        @bytes[index / 8] |= (1 << (index % 8))
        true
      end

      def include?(index)
        check!(index)
        @bytes[index / 8].anybits?(1 << (index % 8))
      end

      def count
        @bytes.sum { |byte| byte.to_s(2).count("1") }
      end

      def to_a
        (0...size).select { |index| include?(index) }
      end

      def to_blob
        @bytes.pack("C*")
      end

      private
        def byte_length = (size / 8.0).ceil

        def check!(index)
          return if index.is_a?(Integer) && index >= 0 && index < size

          raise ArgumentError, "piece #{index} is outside this object's #{size} pieces"
        end
    end
  end
end
