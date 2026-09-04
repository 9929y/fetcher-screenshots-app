# Fetcher

A macOS screenshot feedback tool for the Figma-to-AI implementation loop.

Fetcher is designed for the moment when a visual implementation is close, but not quite right: drag a region, mark the issue, write what needs to change, and export a package that includes both the annotated screenshot and a numbered instruction list an AI coding assistant can follow.

## Why It Exists

AI implementation feedback often loses precision when visual critique becomes plain text. Fetcher keeps the visual evidence and the instruction together, so the next coding pass can see exactly where the issue is and what decision should change.

The product idea is simple:

- Capture only the relevant part of the screen.
- Let the reviewer mark what is wrong without switching context.
- Turn visual critique into structured implementation instructions.
- Preserve the screenshot and instructions as one review package.

## Core Workflow

1. Drag a box around the UI area that needs review.
2. Add a short note describing what is wrong or what should change.
3. Press return to export the marked-up screenshot and model-readable instruction list.
4. Paste or attach the result into the implementation loop.

## Product Role

Fetcher is useful as a small but sharp piece of AI-builder workflow infrastructure. It shows the kind of tool I care about: not another generic screenshot utility, but a bridge between design review and implementation correction.

The value is in reducing ambiguity:

- Designers can point to exact UI problems.
- Builders can receive visual context with numbered instructions.
- AI agents can use the same artifact as both image evidence and task list.

## Current Status

The public `main` branch currently contains a short README only. The previous README references a `FetcherV1` branch, but the current shallow scan only found `main`. Before publication, the implementation branch and app source should be reviewed and merged intentionally.

## Recommended Repo Description

macOS screenshot feedback tool for turning Figma-to-AI visual critique into annotated images and structured implementation instructions.

## Suggested Topics

`macos`, `design-tools`, `figma`, `ai-workflow`, `screenshot-tool`, `product-design`, `ai-builder`
