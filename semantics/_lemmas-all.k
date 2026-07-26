requires "opcodes/whitelists.k"
requires "opcodes/invalidatetokenout.k"
requires "opcodes/xycswap.k"
requires "opcodes/jumps.k"
requires "opcodes/privateorder.k"
requires "opcodes/txorigin.k"
requires "opcodes/supplyshare.k"
requires "opcodes/gte.k"
requires "opcodes/deadline.k"
requires "opcodes/extruction.k"
requires "opcodes/jump.k"
requires "opcodes/salt.k"
requires "opcodes/revert.k"
requires "opcodes/stop.k"
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
  imports SWAPVM-STOP
  imports SWAPVM-REVERT
  imports SWAPVM-SALT
  imports SWAPVM-JUMP
  imports SWAPVM-EXTRUCTION
  imports SWAPVM-DEADLINE
  imports SWAPVM-GTE
  imports SWAPVM-SUPPLYSHARE
  imports SWAPVM-TXORIGIN
  imports SWAPVM-PRIVATEORDER
  imports SWAPVM-JUMPS
  imports SWAPVM-WHITELISTS
  imports SWAPVM-INVALIDATETOKENOUT
  imports SWAPVM-XYCSWAP

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

  // Indexing inside the RIGHT operand shifts down by the left's length. The mirror of the
  // rule above, and just as necessary: in a program built from several chunks, the opcode and
  // args-length bytes of any instruction after the first fall in a right operand. Its absence
  // stalled the pricing claim at pc 22 -- it could not read the args-length byte of the second
  // instruction.
  rule (B1 +Bytes B2) [ I ] => B2 [ I -Int lengthBytes(B1) ]
    requires lengthBytes(B1) <=Int I
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

  // A slice STRADDLING the concatenation point splits at the boundary. Needed as soon as a
  // program is built from more than two chunks: decoding an instruction's arguments slices
  // across whatever Int2Bytes pieces the claim used to describe them. Without this the prover
  // stalls at the first such instruction -- observed at pc 22 of the pricing claim, which had
  // decoded the gate and could not slice the balances.
  rule substrBytes(B1 +Bytes B2, S, E)
    => substrBytes(B1, S, lengthBytes(B1)) +Bytes substrBytes(B2, 0, E -Int lengthBytes(B1))
    requires 0 <=Int S andBool S <Int lengthBytes(B1) andBool lengthBytes(B1) <Int E
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
