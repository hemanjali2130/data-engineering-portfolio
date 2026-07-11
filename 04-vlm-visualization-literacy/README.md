# VLM Visualization Literacy Evaluation

**Resume project:** VLM Visualization Literacy Evaluation - Graduate Capstone

## Status and evidence

This is a report-backed graduate capstone co-authored by Hemanjali Buchireddy.
The report evaluated GPT-5.4 on the ChartX benchmark and is the current evidence for
the methodology and findings below. The source evaluation code is maintained separately
and has not yet been imported into this portfolio repository.

## What the capstone evaluated

- 6,000 ChartX images across 18 chart types and 22 academic domains.
- Deterministic vision-language evaluation at temperature 0.
- Five concurrent requests with exponential backoff and JSON response caching.
- Relaxed numeric and keyword-based automated scoring.
- A comparison of two-dimensional charts and 3D-rendered bar charts.

## Report-backed findings

| Finding | Result |
|---|---:|
| Two-dimensional evaluation accuracy | 85.7% on 5,713 successfully scored images |
| Position-encoded chart performance | 91-95% for the strongest bar and line chart types |
| Treemap accuracy | 51.6% |
| 3D-bar accuracy | 59.3% |
| 3D performance gap | 26 percentage points versus the comparable 2D bar baseline |
| Design output | Six guidelines for VLM-assisted immersive analytics |

Seven two-dimensional API requests had transient failures and were excluded from the
5,713-image accuracy denominator. The 6,000-image claim describes the full benchmark
batch attempted by the evaluation pipeline.

## Interview explanation

> I co-built a deterministic evaluation pipeline for GPT-5.4 on the ChartX visualization
> benchmark. We processed the 6,000-image benchmark with concurrency controls, retry
> handling, JSON caching, and automated scoring. The result was 85.7% accuracy on the
> successfully scored 2D images, but performance dropped sharply on area encodings and
> 3D bars. We used those failure modes to propose six design guidelines for VLM-assisted
> immersive analytics.

## Portfolio completion note

To make this project independently reproducible from GitHub, add the de-identified
evaluation source, dependency lockfile, dataset preparation instructions, prompt
template, and aggregate result tables. Do not commit API keys, raw cached model
responses containing sensitive data, or proprietary course material.
