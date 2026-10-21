---
type: Explanation
title: "Engine Choice"
description: "why llama.cpp (lemonade) is the decode path: lemonade Q8XL ~22 GB/card vs vLLM FP8 ~28 GB of 32, they can't coexist"
resource: docs/explanation/engine-choice.md
generated: { by: human:faultytechnology, at: 2026-10-20T12:00:00Z }
---

# Engine Choice

why llama.cpp (lemonade) is the decode path: lemonade Q8XL ~22 GB/card vs vLLM FP8 ~28 GB of 32, they can't coexist.

Pointer concept: the canonical record is [docs/explanation/engine-choice.md](../../docs/explanation/engine-choice.md).
Measurements, decision history and errata live there, not here — keep this file
to one screen.
