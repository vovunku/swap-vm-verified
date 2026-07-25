# Scratch lemma files

One file per agent: `scratch-<Instruction>.k`. An agent writes every rule it discovers here
and never touches `lemmas.k`, so concurrent agents cannot collide — integration into the
shared library is a coordinator step that happens later, on evidence of firing.

These files are kept after merging rather than deleted. A rule that did not fire is a record
of a term shape KEVM does not produce, which is exactly the knowledge that stops the next
agent repeating the attempt.

See `../analysis/AGENT-PROTOCOL.md` for the ownership rule, the firing-evidence requirement,
and why rules containing a partial symbol (`/Int`, `%Int`, `modInt`) cannot be tested with
`--lemmas` at all.
