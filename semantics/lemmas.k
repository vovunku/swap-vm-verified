requires "swapvm.md"

// Bytes simplification for symbolic programs.
//
// These are NOT domain facts about SwapVM. They are generic identities about `+Bytes`,
// `substrBytes`, `Int2Bytes` and `Bytes2Int` that plain K does not ship, and without them a
// symbolic program built by concatenation cannot be decoded: the prover cannot reduce
// `(b"\x23\x14" +Bytes ... +Bytes TAIL) [ 0 ]` to `0x23`.
//
// Each is a definitional property of the operation, with the side condition that makes it
// total. They are recorded in axioms.md as generic-bytes, distinct from instruction rules.
module SWAPVM-BYTES-LEMMAS
  imports SWAPVM

  // Length of a concatenation. Definitional.
  rule lengthBytes(B1 +Bytes B2) => lengthBytes(B1) +Int lengthBytes(B2)
    [simplification]

  // Int2Bytes produces exactly the requested width.
  rule lengthBytes(Int2Bytes(N, _:Int, _:Endianness)) => N
    requires N >=Int 0
    [simplification]

  // Indexing inside the left operand ignores the right.
  rule (B1 +Bytes _) [ I ] => B1 [ I ]
    requires 0 <=Int I andBool I <Int lengthBytes(B1)
    [simplification]

  // A slice wholly inside the left operand ignores the right.
  rule substrBytes(B1 +Bytes _, S, E) => substrBytes(B1, S, E)
    requires 0 <=Int S andBool S <=Int E andBool E <=Int lengthBytes(B1)
    [simplification]

  // A slice wholly inside the right operand shifts down by the left's length.
  rule substrBytes(B1 +Bytes B2, S, E)
    => substrBytes(B2, S -Int lengthBytes(B1), E -Int lengthBytes(B1))
    requires lengthBytes(B1) <=Int S andBool S <=Int E
    [simplification]

  // A slice covering the whole of a value is that value.
  rule substrBytes(B, 0, E) => B
    requires E ==Int lengthBytes(B)
    [simplification]

  // Round-trip. The width bound is what makes it exact rather than truncating.
  rule Bytes2Int(Int2Bytes(N:Int, V:Int, BE), BE, Unsigned) => V
    requires N >=Int 0 andBool 0 <=Int V andBool V <Int (2 ^Int (8 *Int N))
    [simplification]

endmodule
