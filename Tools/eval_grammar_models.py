#!/usr/bin/env python3
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def build_prompt(template: str, text: str) -> str:
    return template.replace("{text}", text)


def normalize(text: str) -> str:
    text = text.strip()
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    return text


def token_count(text: str) -> int:
    return len(re.findall(r"\w+|[^\w\s]", text, flags=re.UNICODE))


def forbidden_wrapper(text: str) -> bool:
    stripped = text.strip()
    return (
        stripped.startswith('"')
        and stripped.endswith('"')
        or stripped.startswith("'")
        and stripped.endswith("'")
        or stripped.startswith("```")
    )


def unwrap_output(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("<output>") and stripped.endswith("</output>"):
        return stripped[len("<output>") : -len("</output>")].strip()
    return text


def call_ollama(model: str, prompt: str, base_url: str, timeout: float) -> str:
    payload = json.dumps(
        {"model": model, "prompt": prompt, "stream": False, "options": {"temperature": 0}}
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    return body["response"].strip()


def evaluate_model(model: str, prompt_variant: dict, cases: list[dict], base_url: str, timeout: float) -> dict:
    results = []
    exact = 0
    wrapped = 0
    length_violations = 0
    start = time.time()

    for index, case in enumerate(cases, start=1):
        print(f"[{model}] case {index}/{len(cases)}: {case['id']}", file=sys.stderr)
        prompt = build_prompt(prompt_variant["template"], case["input"])
        output = call_ollama(model, prompt, base_url=base_url, timeout=timeout)
        output = unwrap_output(output)
        norm_output = normalize(output)
        norm_expected = normalize(case["expected"])
        input_tokens = token_count(case["input"])
        output_tokens = token_count(output)
        is_exact = norm_output == norm_expected
        is_wrapped = forbidden_wrapper(output)
        too_long = output_tokens > input_tokens + 3

        exact += int(is_exact)
        wrapped += int(is_wrapped)
        length_violations += int(too_long)

        results.append(
            {
                "id": case["id"],
                "input": case["input"],
                "expected": case["expected"],
                "output": output,
                "exact_match": is_exact,
                "wrapped": is_wrapped,
                "too_long": too_long,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
            }
        )

    elapsed = time.time() - start
    return {
        "model": model,
        "prompt_variant": prompt_variant["id"],
        "case_count": len(cases),
        "exact_match_count": exact,
        "exact_match_rate": exact / len(cases),
        "wrapped_count": wrapped,
        "length_violation_count": length_violations,
        "elapsed_seconds": elapsed,
        "avg_seconds_per_case": elapsed / len(cases),
        "results": results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate grammar-fix quality across Ollama models.")
    parser.add_argument("--models", nargs="+", required=True, help="Ollama model names")
    parser.add_argument(
        "--cases",
        default=str(Path(__file__).with_name("grammar_eval_cases.json")),
        help="Path to evaluation cases JSON file",
    )
    parser.add_argument(
        "--prompts",
        default=str(Path(__file__).with_name("grammar_prompt_variants.json")),
        help="Path to grammar prompt variants JSON file",
    )
    parser.add_argument(
        "--prompt-ids",
        nargs="+",
        help="Optional prompt variant ids to run",
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:11434", help="Ollama base URL")
    parser.add_argument("--timeout", type=float, default=120.0, help="Per-request timeout in seconds")
    parser.add_argument("--limit", type=int, help="Optional maximum number of cases to run")
    parser.add_argument("--output", help="Optional JSON output path")
    args = parser.parse_args()

    cases = json.loads(Path(args.cases).read_text())
    prompt_variants = json.loads(Path(args.prompts).read_text())
    if args.limit:
        cases = cases[: args.limit]
    if args.prompt_ids:
        prompt_variants = [p for p in prompt_variants if p["id"] in set(args.prompt_ids)]
        if not prompt_variants:
            print("No matching prompt variants found.", file=sys.stderr)
            return 1
    summaries = []

    for model in args.models:
        for prompt_variant in prompt_variants:
            try:
                summary = evaluate_model(
                    model,
                    prompt_variant,
                    cases,
                    base_url=args.base_url,
                    timeout=args.timeout,
                )
            except urllib.error.URLError as exc:
                print(f"[error] {model}/{prompt_variant['id']}: {exc}", file=sys.stderr)
                return 1
            summaries.append(summary)

    text_lines = []
    for summary in summaries:
        text_lines.append(
            f"{summary['model']} [{summary['prompt_variant']}]: "
            f"exact={summary['exact_match_count']}/{summary['case_count']} "
            f"({summary['exact_match_rate']:.0%}), "
            f"wrapped={summary['wrapped_count']}, "
            f"too_long={summary['length_violation_count']}, "
            f"avg={summary['avg_seconds_per_case']:.2f}s"
        )

    print("\n".join(text_lines))

    if args.output:
        Path(args.output).write_text(json.dumps(summaries, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
