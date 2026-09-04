# Fetcher Product Notes

## Positioning

Fetcher is a workflow tool for AI-assisted design implementation. Its job is to make visual QA less vague by pairing a screenshot region with explicit, ordered correction instructions.

It fits Yanice's GitHub profile as evidence of:

- AI-builder workflow design
- Design-to-code review systems
- Small tool product thinking
- Practical UX for repeated implementation loops

## Product Insight

The painful part of Figma-to-code iteration is rarely "can I take a screenshot?" It is:

- explaining exactly which visual mismatch matters,
- keeping the critique attached to the right pixels,
- translating taste/design feedback into implementation steps,
- and making the next model or engineer act on the same evidence.

Fetcher turns that into a tiny operating loop.

## Public Framing

Use language like:

```text
Fetcher is a macOS screenshot feedback tool for AI-assisted UI implementation. It packages a marked-up screen region and a numbered instruction list so visual critique can move cleanly into the next build pass.
```

Keep the public copy focused on the product loop and the implementation value. Process notes and build-history details should stay outside the public-facing product notes.

## Cleanup Decisions Before Publish

The current remote scan found only `main` with a short README. The README says to see `FetcherV1`, but that branch was not present in the shallow clone's remote branch list.

Before making this repo public or foregrounding it:

1. Confirm where the actual implementation lives.
2. Confirm whether `FetcherV1` still exists locally, in another remote, or under a renamed branch.
3. Review implementation files for screenshots, source-only machine paths, design assets, tokens, app bundle settings, or process logs.
4. Replace the README with `repo_cleanup_source/fetcher/README.md` after implementation is present or after deciding this repo should stay a concept note.
5. Add a minimal demo image or GIF only after confirming it shows generic UI.

## Recommended Repo Description

macOS screenshot feedback tool for annotated Figma-to-AI implementation reviews.

## Suggested Topics

`macos`, `figma`, `design-qa`, `ai-workflow`, `screenshot-tool`, `design-engineering`
