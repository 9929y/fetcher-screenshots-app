# Fetcher Product Notes

## Positioning

Fetcher is a workflow tool for designers who implement with AI. Its job is to
make visual QA less vague by pairing a screenshot region with explicit, ordered
correction instructions.

It fits Yanice Yang's GitHub profile as evidence of:

- AI-builder workflow design
- Design-to-code review systems
- Small tool product thinking
- Practical UX for repeated implementation loops
- Native macOS engineering without an Xcode project

## Product insight

The painful part of Figma-to-code iteration is rarely "can I take a
screenshot?" It is:

- explaining exactly which visual mismatch matters,
- keeping the critique attached to the right pixels,
- translating taste and design feedback into implementation steps,
- and making the next model or engineer act on the same evidence.

Fetcher turns that into a tiny operating loop: capture, mark, write, hand off.

## Product decisions

- **Two outputs, one artifact.** The annotated PNG and the numbered prompt are
  produced together and stay in step. The model reads the list, the human reads
  the picture, and both point at the same numbers.
- **Clipboard and disk, always.** Cursor accepts a pasted image; Claude Code and
  Codex want a path. Writing every capture to disk serves both without a mode.
- **Keyboard-first, visibly.** The fast path is all shortcuts, but Undo, Discard
  and Copy are on the toolbar because a shortcut nobody can see does not exist.
- **Trust over taste.** Color order and numbering are not configurable. Color
  names in the prompt are derived from the actual color so a recolor cannot make
  the prompt lie.
- **Preview is the export.** The editor draws with the same compositor code as
  the export, at a different scale, so what you see is what the model gets.

## Public framing

```text
Fetcher is a macOS screenshot tool for designers who build with AI. It packages
a marked-up screen region and a numbered instruction list so visual critique can
move cleanly into the next build pass.
```

Keep the public copy focused on the product loop and the implementation value.

## Repo description

macOS screenshot tool for designers collaborating with AI: annotate a region, write the fix, hand over an image plus a numbered instruction list.

## Topics

`macos`, `swift`, `figma`, `design-tools`, `design-qa`, `ai-workflow`,
`screenshot-tool`, `design-engineering`, `product-design`
