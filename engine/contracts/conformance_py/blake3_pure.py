"""Pure-Python BLAKE3 (unkeyed, default 32-byte output). Stdlib only.

Exists because the compiled `blake3` PyPI wheel is not guaranteed present on
every Python this conformance suite runs under (verified 2026-07-11: this
Mac's default `python3` is 3.14.4 via Homebrew, and `import blake3` fails there
with the package not installed; a cp314 wheel does exist on PyPI but installing
it is an extra setup step this lane's boot-test one-liner must not require).
`blake3_compat.py` prefers the real compiled package when it is importable and
falls back to this implementation otherwise; both paths are required to agree,
which is checked directly in test_conformance.py.

Implements the algorithm from the BLAKE3 specification: chunked compression
(1024-byte chunks, 64-byte blocks, a 7-round permuted quarter-round compression
function derived from ChaCha), with chaining values from completed chunks
merged into a binary tree via a chaining-value stack, matching the reference
implementation's structure. Cross-checked byte-for-byte against the compiled
`blake3` package across 39 inputs spanning 0 bytes through 65537 bytes
(covering empty input, sub-block, block-boundary, chunk-boundary, and
multi-chunk tree-merge cases) before being trusted for this lane's fixtures;
see docs/evidence/p0c-contracts.md for the verification note.
"""

OUT_LEN = 32
BLOCK_LEN = 64
CHUNK_LEN = 1024

CHUNK_START = 1
CHUNK_END = 2
PARENT = 4
ROOT = 8

IV = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
      0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]

MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

MASK32 = 0xFFFFFFFF


def _mask32(x):
    return x & MASK32


def _rotr32(x, n):
    return _mask32((x >> n) | (x << (32 - n)))


def _g(state, a, b, c, d, mx, my):
    state[a] = _mask32(state[a] + state[b] + mx)
    state[d] = _rotr32(state[d] ^ state[a], 16)
    state[c] = _mask32(state[c] + state[d])
    state[b] = _rotr32(state[b] ^ state[c], 12)
    state[a] = _mask32(state[a] + state[b] + my)
    state[d] = _rotr32(state[d] ^ state[a], 8)
    state[c] = _mask32(state[c] + state[d])
    state[b] = _rotr32(state[b] ^ state[c], 7)


def _round(state, m):
    _g(state, 0, 4, 8, 12, m[0], m[1])
    _g(state, 1, 5, 9, 13, m[2], m[3])
    _g(state, 2, 6, 10, 14, m[4], m[5])
    _g(state, 3, 7, 11, 15, m[6], m[7])
    _g(state, 0, 5, 10, 15, m[8], m[9])
    _g(state, 1, 6, 11, 12, m[10], m[11])
    _g(state, 2, 7, 8, 13, m[12], m[13])
    _g(state, 3, 4, 9, 14, m[14], m[15])


def _permute(m):
    return [m[i] for i in MSG_PERMUTATION]


def _compress(chaining_value, block_words, counter, block_len, flags):
    state = list(chaining_value) + list(IV[0:4]) + [
        _mask32(counter),
        _mask32(counter >> 32),
        block_len,
        flags,
    ]
    block = list(block_words)
    for r in range(7):
        _round(state, block)
        if r < 6:
            block = _permute(block)
    for i in range(8):
        state[i] = _mask32(state[i] ^ state[i + 8])
        state[i + 8] = _mask32(state[i + 8] ^ chaining_value[i])
    return state


def _first_8(words):
    return words[0:8]


def _words_from_le_bytes(b):
    padded = bytes(b) + b"\x00" * (BLOCK_LEN - len(b))
    return [int.from_bytes(padded[i:i + 4], "little") for i in range(0, BLOCK_LEN, 4)]


class _Output:
    __slots__ = ("icv", "block_words", "counter", "block_len", "flags")

    def __init__(self, icv, block_words, counter, block_len, flags):
        self.icv = icv
        self.block_words = block_words
        self.counter = counter
        self.block_len = block_len
        self.flags = flags

    def chaining_value(self):
        return _first_8(_compress(self.icv, self.block_words, self.counter, self.block_len, self.flags))

    def root_output_bytes(self, out_len):
        out = bytearray()
        output_block_counter = 0
        while len(out) < out_len:
            words = _compress(self.icv, self.block_words, output_block_counter, self.block_len, self.flags | ROOT)
            for w in words:
                out.extend(w.to_bytes(4, "little"))
                if len(out) >= out_len:
                    break
            output_block_counter += 1
        return bytes(out[:out_len])


class _ChunkState:
    def __init__(self, chaining_value, chunk_counter, flags):
        self.chaining_value = chaining_value
        self.chunk_counter = chunk_counter
        self.block = bytearray()
        self.block_len = 0
        self.blocks_compressed = 0
        self.flags = flags

    def len(self):
        return BLOCK_LEN * self.blocks_compressed + self.block_len

    def start_flag(self):
        return CHUNK_START if self.blocks_compressed == 0 else 0

    def update(self, input_bytes):
        idx = 0
        n = len(input_bytes)
        while idx < n:
            if self.block_len == BLOCK_LEN:
                block_words = _words_from_le_bytes(bytes(self.block))
                self.chaining_value = _first_8(_compress(
                    self.chaining_value, block_words, self.chunk_counter,
                    BLOCK_LEN, self.flags | self.start_flag()))
                self.blocks_compressed += 1
                self.block = bytearray()
                self.block_len = 0
            want = BLOCK_LEN - self.block_len
            take = min(want, n - idx)
            self.block.extend(input_bytes[idx:idx + take])
            self.block_len += take
            idx += take

    def output(self):
        block_words = _words_from_le_bytes(bytes(self.block))
        return _Output(self.chaining_value, block_words, self.chunk_counter,
                        self.block_len, self.flags | self.start_flag() | CHUNK_END)


def _parent_output(left_cv, right_cv, key_words, flags):
    return _Output(key_words, list(left_cv) + list(right_cv), 0, BLOCK_LEN, PARENT | flags)


def _parent_cv(left_cv, right_cv, key_words, flags):
    return _parent_output(left_cv, right_cv, key_words, flags).chaining_value()


class Hasher:
    """Minimal unkeyed BLAKE3 hasher. update() then hexdigest()/digest()."""

    def __init__(self):
        self.key_words = list(IV)
        self.flags = 0
        self.chunk_state = _ChunkState(list(self.key_words), 0, self.flags)
        self.cv_stack = []

    def _push(self, cv):
        self.cv_stack.append(cv)

    def _pop(self):
        return self.cv_stack.pop()

    def _add_chunk_chaining_value(self, new_cv, total_chunks):
        while total_chunks & 1 == 0:
            new_cv = _parent_cv(self._pop(), new_cv, self.key_words, self.flags)
            total_chunks >>= 1
        self._push(new_cv)

    def update(self, input_bytes):
        idx = 0
        n = len(input_bytes)
        while idx < n:
            if self.chunk_state.len() == CHUNK_LEN:
                chunk_cv = self.chunk_state.output().chaining_value()
                total_chunks = self.chunk_state.chunk_counter + 1
                self._add_chunk_chaining_value(chunk_cv, total_chunks)
                self.chunk_state = _ChunkState(list(self.key_words), total_chunks, self.flags)
            want = CHUNK_LEN - self.chunk_state.len()
            take = min(want, n - idx)
            self.chunk_state.update(input_bytes[idx:idx + take])
            idx += take
        return self

    def finalize(self, out_len=OUT_LEN):
        output = self.chunk_state.output()
        parent_nodes_remaining = len(self.cv_stack)
        while parent_nodes_remaining > 0:
            parent_nodes_remaining -= 1
            output = _parent_output(
                self.cv_stack[parent_nodes_remaining],
                output.chaining_value(),
                self.key_words,
                self.flags,
            )
        return output.root_output_bytes(out_len)

    def digest(self, out_len=OUT_LEN):
        return self.finalize(out_len)

    def hexdigest(self, out_len=OUT_LEN):
        return self.finalize(out_len).hex()


def blake3_hex(data: bytes) -> str:
    """Return the 64-char lowercase hex BLAKE3 digest of data."""
    h = Hasher()
    h.update(data)
    return h.hexdigest()
