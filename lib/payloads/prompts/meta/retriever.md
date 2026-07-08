## Retriever -- trace sampling and cross-reference policy

The trace corpus and the harness source you cite are described after the
meta-skill components (absolute paths). The corpus is large -- sample and
grep it; do NOT assume it fits in context.

File ONLY issues that recur across >=2 INDEPENDENT traces (different
sessions or children). Note a striking one-off in passing, but do not
file it as a recommendation.

When diagnosing a failure, over-fetch a wider pool of candidate traces (at
least 3x the number you will cite) and then narrow to the most relevant ones
by re-reading their content. This guards against a single unrepresentative
trace driving a wrong diagnosis.

Read `learnings.md` and `overlays/*.md` (including `meta-*.md` overlays)
before proposing anything already addressed.