<!--
Copyright 2026 Filippo Rossi
SPDX-License-Identifier: Apache-2.0
-->

# Arrow Zig — Productionization Review

Reviewed the full `src/` tree against the Arrow C++ reference, ran `zig build ci`, and cross-checked a handful of subtle areas (bitmap word reads, union null semantics, decimal precision limits, list-view buffer kinds, CDI invariants).

Overall the codebase is in **very good shape for a v0.x library**. It is small, internally consistent, idiomatic Zig (no needless C-isms), thoroughly tested, validates inputs at boundaries, and uses comptime + tagged unions to replace the C++ vtable hierarchy without losing any spec features in the data-model layer. The CDI implementation is unusually thorough and is cross-validated against nanoarrow in CI.

The biggest visible gap is what the README already calls out: no compute layer beyond `compare`, no IPC, no Parquet, no chunked-array/table layer. Items below assume those are intentionally future work; everything here is about polishing what already exists.

A first review pass has already landed on several items in the working tree — those are marked **Done** below with a short note on what shipped.

---

## A. Correctness

### A1. Sparse-union null semantics divergence from C++ — **Done**

C++ (`arrow/util/union_util.cc`) calls `span.child_data[child_id].IsNull(i)` for sparse unions with the *logical* index, and calls dense-union children with the stored child offset. The Zig code was passing `data.offset + i` to sparse children, which compounded offsets whenever the parent was pre-sliced.

The working tree fixes this: `src/array/data.zig:319` now calls `data.children[child_index].isNull(i)` and `validate.zig` enforces `child.offset == 0` for union children via a new `ChildOffsetMismatch` error.

**Follow-up:** the same convention is now load-bearing in `denseUnionSlotIsNull`, where `child_offset` from the offsets buffer is used as-is. That call site is currently correct under the invariant, but it should grow an assertion or doc-comment so a future "fix" doesn't reintroduce the bug.

### A2. `BufferKind` enumerator for list-view children — **Done**

The two list-view child buffers were both tagged `.values` with comments saying "should be offsets/sizes". The working tree now tags list-view buffers as validity, offsets, and sizes; `cdi/array_import.zig` accounts for `.sizes` when computing visible buffer size.

### A3. List-view `valueRange` does not validate sizes

`VarListViewArray.valueRange` (`src/array/list.zig:127`) reads offset and size via `@intCast` without checking sign or fit. For an externally-supplied bad list-view (validation skipped), this can produce nonsense. `data.validate()` catches it, but the type does not *prevent* unchecked construction. Two options:

- Return an error from `fromData` if `data.len > 0` and you want to be defensive without full validation, or
- Document that `validateFull()` is mandatory before reading list-view arrays.

### A4. `Buffer.allocate(0)` returned an undefined pointer — **Done**

Zero-length buffers now use an explicit sentinel address, so `dataSlice().ptr` and `mutableSlice().ptr` are stable even when `size == 0`. This closes a real C-interop bug class where a zero-length buffer pointer might still be handed to CDI or libc code.

---

## B. API / surface polish

### B1. Redundant `slice` vs `sliceChecked` — **Done**

Both methods existed and behaved identically. `sliceChecked` is now gone; all call sites use `slice`. Test sites in `compute/compare/*.zig` updated.

### B2. List builders' `appendEmpty` is `appendEmptyValue`'s twin — **Done**

`appendEmpty` is removed from list and map builders. The map-builder test that used it now calls `appendEmptyValue`. The list-builder test that called `appendEmpty` was updated to expect a 3-element array (one fewer slot) and adjusted index assertions.

### B3. `Schema.fieldIndex` is O(N)

Linear scan over `field_meta` for every `columnNamed` lookup. Lazily memoize a `std.StringHashMap` on first lookup; invalidate on `addField`/`setField`/`removeField`/`selectFields` which already build new schemas.

### B4. `Field.create` vs `Field.initOwned`

The dual API (clone-and-take vs take-already-owned) is good, but the contract lives in comments. Rename `initOwned` → `initTakeOwnership` (or `fromOwnedParts`) so the calling convention is obvious at the call site, and tighten the doc on `create` to distinguish "retain the type" (refcount bump on field children) from "deep clone via `cloneTypePtr`" (recursive clone of nested type wrappers).

### B5. `RecordBatch.fromStructDataRetainedSchema` calls `validateFull` — **Done**

Right default for safety; quadratic when CDI import is the caller and already validated. The working tree now exposes `fromStructDataAssumeValidated`, uses a contract-only internal constructor for that path, and lets CDI record-batch import skip the second column-validation pass after `importArray` has already run `validateFull`.

---

## C. Code organization

### C1. Duplicate `childIndexFor` implementations — **Done**

Hoisted to `array/data.zig` as `pub fn childIndexFor`. `array/union.zig` and `array/validate.zig` had their local copies removed.

### C2. Multiple signed→usize helpers — **Done**

A single `checked.toUsize` now lives in `src/checked.zig` and is delegated to from `offsets.toUsize`, `array/data.zig`'s `runEndAsUsize`/`indexAsUsize`, `builder/union.zig`'s `intAsUsize`, and `validate.zig`'s `runEndToUsize`. The compute/compare common helper was left untouched in the partial pass — worth a look.

### C3. `validate.zig` is 1011 lines — **Promote to higher priority**

The original review listed this as polish. I'd promote it. Validation is where silent divergence from the spec is most expensive, and per-type validators are independent — moving each into a sibling of its array file (`array/list.zig` gets its own `validate`, called from a thin dispatcher in `validate.zig`) makes the spec-compliance audit shorter and matches the layout C++ uses for builders. Day's work; payoff compounds once IPC lands.

### C4. List builder `clearListState(clear_field_options)`

The pattern of "destroying state with a comptime boolean controlling whether owned strings get freed" is repeated in `list.zig`, list-view, fixed-size-list builders, and `union.zig`. Brittle (the boolean's meaning is not obvious). A `FieldOptions` struct that owns its strings and deinits itself removes the dual-state.

### C5. Builder error sets — **Tried and reverted**

A `common.BaseError(specific)` helper was prototyped, then removed. Reasons documented for the record:

- The name read like a constructor for an *instance*, but the call shape was a type-set union.
- The empty-suffix case (`NullBuilder`) was forced to write `common.BaseError(error{})` purely to satisfy the signature.
- It hid the actual error set behind one level of indirection — every reader has to click through to `common.zig` to know what `BaseError` adds. The pre-refactor `Allocator.Error || checked.Error || error{X, Y}` form is two tokens longer but reads at a glance.
- It centralized the *common prefix*, but the per-builder *suffixes* (`UnclosedListValues`, `ViewOutOfBounds`, etc.) are where real divergence and duplication live. A more useful refactor would name shared *suffix groups* — e.g. `OffsetError = error{NegativeOffset, OffsetOverflow}` shared by list/map/string builders.

Net: leave error sets inline. Revisit only if a fourth common base term shows up (e.g. a `Bitmap.Error` threaded through every builder).

### C6. `array.zig` is purely a re-export file

Same for `bitmap.zig`. Consider re-exporting the most common shapes (`NumericArray`, `BooleanArray`, common builders) directly from `root.zig` so users write `arrow.NumericArray(i32)` rather than `arrow.array.NumericArray(i32)`.

### C7. `Buffer.deinit` leaves stale field values pre-destroy

Cheap zero-fill of `self.*` before `allocator.destroy(self)` would make use-after-free easier to spot under debug allocators. Optional, low priority.

---

## D. Documentation

### D1. The CDI module's pre-conditions — **Done, but keep auditing**

`cdi.zig` now has a top-level narrative covering import/export ownership, consumption of only the top-level `ArrowArray`, moved-array release timing, imported-buffer immutability, producer padding, and record-batch struct-null behavior. Keep the lifetime/error-path audit below as a separate correctness task.

### D2. `validate` vs `validateFull` distinction — **Done**

Doc-comments now on both methods in `src/array/data.zig`: `validate` = O(1) structural checks, `validateFull` = O(N) value-content checks (UTF-8, monotonicity, dict bounds, run-end values, date64 alignment, time bounds, view prefix verification).

### D3. Slicing semantics for nested types — **Done**

A doc-comment on `ArrayData.slice` now spells out "children are not sliced when the parent is sliced; children are addressed via logical index in `[0, parent.len)`," and `sparseUnionSlotIsNull`/`denseUnionSlotIsNull` carry a one-line restatement of the invariant.

### D4. README "C++ Parity Matrix" undersells some pieces

`extension`, `interval`, decimals 32/64/256, list-view, union with sparse/dense — all present and tested. The "Data types: Complete" row is right; the rows below are conservatively worded. Worth listing explicitly what is tested via nanoarrow interop, since that is the strongest interop-readiness signal you have.

---

## E. Gaps the first-pass review missed

### E1. Lifetime / ref-count audit under error paths

Lots of `*Buffer` ref-counting flows through `ArrayData`, `external_owner`, `ExternalOwnerHandle`, and CDI import. No existing audit asks whether retain/release pairs balance in *error paths*. For a production-targeted library, the next bug class after correctness is leaks under failure — worth a focused pass with `std.testing.allocator` and an injected-OOM harness, particularly on CDI import.

### E2. Fuzz targets

A library whose main job is parsing untrusted bytes (CDI import, `validateFull` against arbitrary buffers) is a textbook fuzzing target. `zig build` already has a test harness — a `zig build fuzz` target wired to `std.testing.fuzz` or an external libfuzzer harness would catch the next A1-class issue before a user does. Scaffolds in a day, pays off forever.

### E3. Architecture overview

There is no architecture document anywhere. README jumps from install to parity matrix to samples. A `docs/architecture.md` (or top-of-`root.zig` section) explaining the four-layer story — `Buffer` (ref-counted bytes) → `ArrayData` (type + buffers + children) → typed `*Array` views → `Builder` — would dramatically shorten onboarding for any future contributor and would naturally absorb the slicing-semantics paragraph from D3. The codebase is small enough today that one page covers it. Once IPC and compute land, that page becomes much harder to write.

---

## F. Performance / quality (lower priority)

These were called out in the original review and I'd still defer them. Without a compute or IPC layer there's no realistic workload to measure against; optimizing now risks committing to micro-shapes the next layer will want to change anyway.

- `compute/compare` uses 32-byte aligned SIMD chunks (`@Vector(32, u8)`), but the bit-packing loop in `writeOrderedValuesScalar` walks 8 lanes at a time scalar. The SIMD/bit-pack glue could be fully vectorized (Arrow C++ uses `BitUtil::WriteBitmap`).
- `Schema.fieldIndex` (see B3).
- `bitmap.copyBits` falls back to a scalar tail when not byte-aligned. The whole-word loop is good; the tail could use the same word-shift trick rather than scalar bit-by-bit.
- `validate.zig`'s `validateBinaryViewLike` reads each view in a loop and (for utf8_view) does `utf8ValidateSlice` per slot. For wide UTF-8 view arrays this is the only path; could use `std.unicode`'s faster validators on contiguous runs.

---

## Suggested priority order for the remaining work

Given a finite week:

1. **E1: lifetime / OOM audit of CDI import** — 1–2 days. CDI is the most exposed public surface; ref-count bugs there are silent.
2. **E2: fuzz target for `validateFull` and CDI import** — 1 day to scaffold, ongoing payoff.
3. **C3: split `validate.zig` per type** — 1 day. Immediate readability payoff and shorter future spec audits.
4. **E3: architecture overview** — half-day. Cheap now, harder once IPC/compute grow.
5. **A3: list-view checked range access or documentation** — half-day. Low risk if users validate first, but worth making explicit.

Deprioritize: everything in F until a real workload (compute, IPC) exists to measure against.

---

## Summary

The Arrow-Zig data model layer, builders, validation, and CDI import/export are production-quality for the scope they cover. Tests are thorough (cross-validated via nanoarrow), code is clear and Zig-idiomatic, no `TODO`/`FIXME` markers, every public type has a doc-comment.

The first-pass review landed A1, A2, A4, B1, B2, B5, C1, C2, D1, D2, and D3. The highest-value items remaining are an **error-path lifetime audit on CDI import**, a **fuzz target** for the validation/import surface, and the **per-type split of `validate.zig`**. Everything else is documentation and polish.
