# Plan: 3code can see — the image pipeline (vision worktree)

## Context (read this first)

3code is text-blind. Every message content on the wire is a string:
`turns.nim` pairs tool results as `{"role":"tool","content": <string>}`,
user input goes through `buildUserMessage` (returns `string`) at four call
sites (`src/threecode.nim:592,645,762`, `library.nim:274`), and `api.nim`'s
Responses translation reads `m{"content"}.getStr("")`. `prompts.nim` even
tells the model "a terminal model cannot by itself inspect an image."

This changes with GLM-5.3-Flash (native multimodal, the recommended default)
and deepseek-v4-flash-vision-exp. The capability we need, in priority order:

1. **User attach**: `@mockup.png rebuild this` — the image rides the user
   message as an image block.
2. **Model reads an image**: `read` on an image file returns a receipt and
   the image rides the following user message. Unlocks Z.ai's headline
   workflows: UI-from-screenshot reproduction, visual inspection of the
   agent's own rendered output.
3. **Screenshots / computer use**: a later phase, specced separately in
   `../computer-use-plan.md` (main worktree). Everything it needs is built
   here; it adds only capture + a `shot` wrapper + `:computer`.

Verified intelligence from the ZCode 3.11.2 teardown (see
`../computer-use-plan.md` for the full evidence) that sets our wire format:

- The standard OpenAI-compat pattern is a **text tool result + image block
  in the following user message** (`[{"type":"text"}, {"type":"image_url",
  "image_url":{"url":"data:image/jpeg;base64,..."}}]`). Tool-message image
  content is not portable; user-message blocks are.
- ZCode delivers JPEG q75, ≤1280 px long edge, inside a **190 KB base64
  budget** with a shrink ladder (quality −15 to floor 40, then ×0.8
  downscale to min edge 320). We adopt the same ladder at q85.
- Providers' prompt caching keys on content bytes: stable re-sends of the
  same base64 (resume) hit cache; mutations bust it. So images are encoded
  once to disk and the exact bytes re-used, never re-encoded per turn.

Non-goals: OCR, image generation, Anthropic-protocol transport, video,
per-image detail levels (no `detail:` field — GLM ignores it), UI rendering
of images in the terminal (banner text only; sixel/kitty is its own project).

## Data flow (the whole design in one paragraph)

An image enters at one of three sources (user `@`, model `read`, future
screenshot). A single encoder turns it into delivered bytes (JPEG q85 ≤1280
in a 190 KB budget, or PNG behind a flag) written once to
`<session-dir>/img/NNN.jpeg`, plus a receipt line (source WxH, delivered
WxH). The harness then constructs a user message whose content is an array:
text block first, one `image_url` block per image. The chat wire passes it
through; the Responses path translates it to `input_text` + `input_image`.
Persistence stores the path + sha1, not base64; resume re-embeds from disk
(same bytes → provider cache hit). Compaction replaces image blocks with a
`[image: name WxH]` text note. Everything downstream that reads user content
as a string learns to take the text part.

## Chunk 1 — image primitives module: `src/threecode/images.nim`

New module, zero imports beyond std (base64, os, strutils, json, hashes,
osproc) — no image library, following the no-new-deps stance. Web-search and
PNG-unfilter decisions stay out; we use platform tools for raster work.

```
type ImageInfo* = object
  width*, height*: int          # source pixels
  deliveredWidth*, deliveredHeight*: int
  format*: string               # "jpeg" | "png"
  path*: string                 # delivered file on disk

proc isImagePath*(path: string): bool
  # extension check: png jpg jpeg webp gif bmp

proc imageDimensions*(path: string): (int, int) {.raises: [].}
  # pure Nim: PNG IHDR (bytes 16..23 big-endian) and JPEG SOF marker scan
  # (walk markers to F0/SOF0-15, read height/width). GIF: bytes 6..9 LE.
  # WebP VP8/VP8L header parse. Unknown → (0, 0), caller decides.

proc encodeForVision*(src, destDir: string, idx: int,
                      fidelity = false): ImageInfo
  # 1. dimensions from imageDimensions; (0,0) → error string return? no:
  #    raises IOError with a plain message; call sites are boundaries that
  #    already speak string errors. Decide: return Result-like
  #    (ImageInfo, string) tuple — match actions.nim conventions.
  # 2. resizer probe (first found): `magick`/`convert` (ImageMagick),
  #    `sips -Z` (macOS). If none found: deliver original bytes if the
  #    base64 of them fits the budget, else error naming the missing tool.
  # 3. budget ladder (only when over): JPEG q85 → q70 → q55 → q40, then
  #    scale ×0.8 (min delivered edge 320) repeating from q85. The ladder
  #    mirrors ZCode's AGENT_B64_BUDGET=190*1024 shrink loop exactly.
  # 4. fidelity=true: PNG, same resize logic, no quality ladder.
  # 5. write destDir/NNN.jpeg (or .png), return ImageInfo. Deterministic:
  #    same source + flags → same delivered bytes (matters for cache).

proc imageUserMessage*(text: string, imgs: seq[ImageInfo]): JsonNode
  # content-array user message; text block first, then one image_url block
  # per image (data URI, base64 of the delivered file). >3 images: attach
  # first 3, note the rest by name in the text block.

proc userTextContent*(m: JsonNode): string
  # the audit helper: content string → itself; array → concatenated
  # text blocks, image blocks → "[image WxH]". This is the ONE accessor
  # every downstream getStr site migrates to.
```

Tests (`tests/core/test_images.nim`, new): generate a 2000x1200 PNG fixture
at test start with the found resizer (skip ladder tests if no resizer — CI
has ImageMagick); assert dimensions parse (PNG, JPEG, GIF, WebP fixtures
checked into `testdata/images/` — tiny files, <2 KB each); assert budget
ladder monotonicity (output b64 ≤ 190 KB); assert `imageUserMessage` shape
against a golden JSON; assert determinism (two encodes, same bytes).

Commit: `add images.nim: dimension parsing, budget encode, message builder`

## Chunk 2 — vision capability flag

`prompts.nim`: `KnownGoodCombo` grows a 13th field `vision: bool`. Every
existing row gets `false`; then seed `true` on the rows the provider is
confirmed to pass images for:

- `("zai", "glm-5.3-flash", ...)` — Z.ai docs: image_url content blocks.
- `("zaicode", ... glm-5.3-flash ...)` if present in this table (check).
- the five `deepseek-v4-flash-vision-exp` rows (variant `flash-vis`).
- OpenRouter GLM-5.3-Flash row: `true` only after a live probe in chunk 8;
  start `false`, flip in the shakedown commit.

`Profile` gains `vision*: bool` (types.nim), set from the known-good lookup
where profiles are built (same place `allowPrivate` resolves — find the
constructor in `config.nim`/`prompts.nim` that maps combos to profiles).
Config escape hatch, mirroring allow-private: `[params] vision = true/false`
per provider+model override, because third-party hostings of vision models
are a patchwork. No new `:` command — errors below teach the fix.

Gate behavior: `visionCapable(p)` is checked at the three image sources;
false → the user gets an inline error naming one known vision model
(e.g. "glm-5.3-flash on zai"), the model gets a tool-result error for
`read`-on-image.

Tests: extend the known-good table test (there is one asserting row shapes
in `tests/api/test_prompts_compact.nim` or config tests — find and extend
for arity 13); unit test the override precedence.

Commit: `known-good table gains vision flag; profile.vision with override`

## Chunk 3 — wire support in `api.nim`

The chat path already forwards `messages` verbatim into the request body, so
a content-array user message serializes correctly with **zero** changes —
verify with the mock server, don't assume. The work:

1. `responsesInput` (api.nim:1055): the `else: result.add m` branch passes
   user messages through; add a case — user message with array content →
   emit `{"type":"input_text","text":...}` plus one
   `{"type":"input_image","image_url":"data:image/jpeg;base64,..."}` per
   image block. (Responses image shape: `input_image` items with data URIs.)
2. Audit every `m{"content"}.getStr` that can see a **user** message and
   route through `userTextContent`: api.nim (the usage/estimation and
   retry-paths around lines 1070, 1177, 1647, 2736 in this worktree —
   `grep -n 'content"}.getStr' src/threecode/api.nim` is the checklist),
   compact.nim:208, session.nim:966/970 (chunk 6 handles session fully).
   Assistant/tool messages stay strings everywhere — nothing else moves.
3. Token estimation (wherever prompt tokens are pre-estimated for the bar):
   images are unknown until the provider reports usage; estimate
   `(deliveredW*deliveredH)/1000` per block, mark estimate as rough.

Tests (`tests/api/test_api.nim` extension): mock-server round trip — feed a
session JSON containing an image user message, assert the outgoing chat body
carries the array verbatim and the Responses body carries `input_image`;
assert no `getStr` crash on array content (fuzz: every message shape).

Commit: `wire: image content blocks pass chat + translate to Responses`

## Chunk 4 — `read` on an image

- `actions.nim` `runAction` akRead branch: `isImagePath(path)` and the
  vision flag (pass `Profile` or just `vision: bool` into runAction — it
  already receives `cache`; add a `vision = false` default param so other
  callers don't change) → encode via `encodeForVision` into
  `<session-dir>/img/`, return receipt as output:
  `image 1920x1080 PNG -> delivered 1280x720 JPEG; attached below`.
  `code` 0. Non-vision: `code` 1 with the error text naming a vision model.
  offset/limit on an image: ignored, note it in the receipt.
- `turns.nim` after the tool batch pairing loop (~line 978 area, where
  `runAction(act, session.readCache)` fires): if any executed action was an
  image read, collect its `ImageInfo`s and append one
  `imageUserMessage("attached: logo.png (image read)", imgs)` user message
  after the last tool result — the exact pattern the computer-use plan and
  the OpenAI-compat CUA world use. Transcript banner: `· read img
  logo.png 1920x1080 -> 1280x720` (display.nim toolResultBytes gains an
  image case; keep it one line).
- Flail detector: image reads are expensive; add `read:<img>` to the
  distinctive-token trimming so repeated image reads of the same file
  escalate. Cap: 4 image attachments per turn, then a note.

Tests: mock-server end-to-end — scripted model calls `read` on a fixture
image, assert request N+1 contains the image block and the tool result is
the text receipt; unit test the receipt format; flail test for repeat reads.

Commit: `read returns images for vision profiles via follow-up user message`

## Chunk 5 — `@image` attach in user input

- `ui.nim` `inlineAtFiles` (line 1291): image extension + vision profile →
  skip text inlining (today a PNG inlines 64 KB of binary garbage), keep the
  `@token` visible, record the resolved path in a side channel.
- `buildUserMessage` (ui.nim:1330) changes return type `string` →
  `JsonNode`: string content when no images, content array when there are
  (preamble text block + image blocks, via `imageUserMessage`). The four
  call sites (`threecode.nim:592,645,762`, `library.nim:274`) change
  `"content": buildUserMessage(...)` — `%*` embeds a JsonNode value
  verbatim, so the diff is the signature, not the sites. Non-vision
  profile: in-message note "attached image ignored: profile is not
  vision-capable (+ hint)", image dropped.
- Editor UX: none beyond the existing `@` completion if it exists for
  files generally; the transcript echo shows `@mockup.png [image attached]`.

Tests: tty visual test for the echo line; unit tests for
`buildUserMessage` string/array duality, preamble handling preserved
(`splitPreamble` in session.nim:751 must keep working — chunk 6 makes it
array-aware via `userTextContent`).

Commit: `@image attaches images to the user message for vision profiles`

## Chunk 6 — persistence, resume, compaction

- `session.nim` emit (line ~966): a user message with array content emits
  the text via `userTextContent`, then one `image` record per block:
  `image <path> <sha1> <WxH>`. Replay (`splitPreamble` inverse path) rebuilds
  the content array by re-embedding from disk when the file and sha1 still
  match; missing/changed file → text note `[image stale: name]`, no block.
  Screenshot-vs-attach difference: none at this layer — both are files on
  disk; resume keeps images because a reference mockup is not stale context
  (and identical bytes re-embed → provider prefix cache hit).
- `compact.nim` (line 208 area): when compacting, image blocks collapse to
  the `[image N]` text note (their bytes already live in earlier history;
  the compacted summary must not carry megabyte blobs). The chunked-mode
  context extractor likewise treats the image note as text.

Tests: save/resume round trip with an image message (file present → array
rebuilt byte-identical; file deleted → stale note); compaction test asserting
no `image_url` blocks survive past the compaction point.

Commit: `persist image messages by path+sha1; compaction collapses to notes`

## Chunk 7 — replay and `:show`

`display.nim` alternate stdout path (the `:show`/`:tools`/replay renderers):
tool records of image reads and user-image echoes render the same one-line
banner. No new chrome. `:show N` on an image read shows the receipt +
delivered size, not the base64.

Tests: tty fixture updates where the new banner appears in existing tests
(only tests that read image files change; grep before patching).

Commit: `replay/:show render image-read banners`

## Chunk 8 — docs + live shakedown (the honesty pass)

- Manual (`docs/manual.md`): "Images" section — @attach, read-on-image,
  the vision table, the budget behavior, the resume rule.
- README feature bullet under "How it pulls it off" or a new "Vision" para.
- CHANGELOG entry.
- Live probe on real endpoints (this is the only step that needs keys):
  zai glm-5.3-flash: `@testdata/images/ui-mockup.png describe this UI, then
  rebuild it as HTML` — verify the image actually reaches the model (it
  describes pixel-level detail), measure prompt-token delta per attached
  image, confirm the budget ladder on a 4K screenshot.
  deepseek flash-vis: same, smaller.
  openrouter glm-5.3-flash: probe; flip the vision flag if images pass.
- Record token-per-image measurements in this plan's appendix for the
  computer-use phases to budget against.

Commit: `docs + vision shakedown notes; flag openrouter if confirmed`

## Acceptance criteria

- `3code` on a non-vision profile: `@x.png` and `read x.png` produce clear
  errors naming a vision model; no wire change, no crash on any path.
- Vision profile: attach and read both deliver `image_url` blocks on the
  chat wire and `input_image` on Responses; tool result text stays text.
- Session file contains paths, not base64; resume re-embeds identical bytes.
- Compaction never carries image blobs forward.
- Full suite green (`nimble test`), plus the new unit + mock-server tests.

## Risks / open questions

- **Provider quirks**: some OpenAI-compat gateways reject content arrays on
  user messages (rare; vLLM/SGLang/LiteLLM all accept). The zai probe in
  chunk 8 is the gate; if a known-good provider chokes, we add a
  per-provider "flatten images to text note" fallback behind the vision
  flag rather than a second code path.
- **Base64 in memory**: a 190 KB b64 is trivial; a 4-image turn ~1 MB of
  JSON — fine for the wire, but the transcript/token-bar estimation must
  not stringify the array anywhere hot (use `userTextContent`, never
  `$m`).
- **PNG source with text**: PNG at 1280 is under budget almost always —
  the ladder rarely fires; the q85 default is for screenshots/photos.
- **Windows**: resizer probe must also try PowerShell
  `Add-Type System.Drawing` resize; defer until the windows sandbox plan
  lands, note it in the manual.
- Where the `img/` dir lives for `library.nim` users without a session dir:
  `%TEMP%`-equivalent under the library's state dir; one helper, decided in
  chunk 1.

## Sequencing

Chunks 1-3 are pure infrastructure, land first in that order. 4 and 5 are
independent of each other after 3; 6 after both; 7 anytime after 4; 8 last.
Each chunk compiles, tests, and commits alone. Computer use then continues
from `../computer-use-plan.md` phases 1+ with phase 0 (there) already done
by chunks 1-6 here.

## Appendix: chunk-8 shakedown record (2026-09-09)

**Verified without keys** (mock-server e2e in `tests/api/test_vision_read.nim`,
plus unit suites): attach and read both produce `image_url` content blocks
in the exact conversation `callModel` sends; tool results stay text; the
follow-up message lands after the tool batch; resume re-embeds
byte-identical URIs from `path+sha1` records; compaction collapses blocks
before the summarizer call; non-vision profiles get the glm-5.3-flash hint
on both paths.

**Live probe: NOT RUN.** The dev sandbox for this worktree denies reading
`~/.config/3code/config` (the main worktree's `.sandbox` allowlists it; the
vision worktree has no policy file, so the default deny applies). Every
probe below still needs one live turn; run from a terminal with the real
config, from this worktree:

- `./3code -m zai.glm-5.3-flash "@testdata/images/ui-mockup.png describe this UI, then rebuild it as HTML"`
  — verify pixel-level detail in the reply (proves the block reached the
  model), note the prompt-token delta per attached image from the receipt,
  and repeat with a 4K screenshot to watch the ladder fire (delivered ≤ 190 KB b64).
- same, smaller, on a `deepseek-v4-flash-vision-exp` hosting.
- openrouter `z-ai/glm-5.3-flash`: if images pass, flip that row's `vision`
  flag in `prompts.nim` (currently false, deliberately).

**Token-per-image measurements: PENDING** the probes above. Until then the
computer-use phases should budget with the wire size (~190 KB b64 max,
~48 KB JPEG typical) and treat provider-side image tokens as unknown.
