#!/usr/bin/env python3
"""Fail-closed qualification of the assertions-on TC32 experiment's lit evidence."""

import json
from pathlib import Path
import re
import shlex
import sys


BASELINE_SHA = "f4856fe098689ceef0543528070c3b4ebc24752a"
REFERENCE_RUN = "34171845355"
PREFIX = "LLVM :: CodeGen/ARM/"
ISLAND_PASS = "ARM constant island placement and branch shortening pass"
SIGNATURES = {
    "immediate-index": (
        'Index < this->size() && "Invalid index!"',
        "TC32 immediate ALU expand",
    ),
    "island-water": (
        'ExpectedWaterList == WaterList && "WaterList drifted from CFG"',
        ISLAND_PASS,
    ),
    "island-size": (
        'Expected.Size == Actual.Size && "stale BBInfo size"',
        ISLAND_PASS,
    ),
    "island-unalign": (
        'Expected.Unalign == Actual.Unalign && "stale BBInfo unalign"',
        ISLAND_PASS,
    ),
    "island-wrong-mi": (
        'Expected.MI == Actual.MI && "ImmBranches tracked wrong MI"',
        ISLAND_PASS,
    ),
}

# Exact pristine-baseline outcomes observed in REFERENCE_RUN, not a TC32 wildcard.
FAILURE_GROUPS = {
    "immediate-index": """
        tc32-add-imm.ll tc32-cmpz-single-bit-shift.ll tc32-cttz-constantpool.ll
        tc32-distinct-dst-addsub.ll tc32-far-unconditional-branch.ll
        tc32-inline-asm-rept-branch.ll tc32-inline-jt-constpool-layout.ll
        tc32-ir-fixup.ll tc32-jump-table-byte.ll tc32-jump-table-halfword.ll
        tc32-jump-table-large.ll tc32-jump-table-sparse.ll tc32-jumptable.ll
        tc32-large-stack-epilogue.ll tc32-no-jump-tables-attr.ll
        tc32-no-multipop-pc-return.ll tc32-packed-byte-load-store.ll
        tc32-signed-ge-zero-branch.ll tc32-singlethread-atomics.ll
        tc32-vararg-pop-pc-epilogue.ll tc32-zero-offset-bcc.ll
    """.split(),
    "island-water": """
        tc32-b-very-far-fallback.mir tc32-bcc-inverted-long.mir
        tc32-bcc-islands-error.mir tc32-bcc-long.mir
        tc32-bcc-very-far-fallback.mir tc32-branch-islands-error.mir
        tc32-branch-islands-nonconverge-error.mir tc32-call-islands-error.mir
        tc32-tb-out-of-range-nonconverge.mir
    """.split(),
    "island-size": """
        tc32-bcc-islands-lrspill-fallback.mir
        tc32-branch-islands-lrspill-fallback.mir
        tc32-call-islands-lrspill-fallback.mir
    """.split(),
    "island-unalign": "tc32-bcc-al-long.mir tc32-bcc-nv-long.mir".split(),
    "island-wrong-mi": """
        tc32-bcc-very-far-backward-fallback.mir
        tc32-call-very-far-backward-fallback.mir
    """.split(),
}
VISIBLE_FAILURES = {
    name: group for group, names in FAILURE_GROUPS.items() for name in names
}
DIAGNOSTIC_CONTROLS = {"tc32-atomic-error.ll", "tc32-ldrex-error.ll"}
BASELINE_PASSES = set("""
    i64_volatile_load_store.ll legalize-unaligned-load.ll
    load-store-pair-volatile.ll memcpy-const-vol-struct.ll memcpy-inline.ll
    memcpy-ldm-stm.ll unaligned_load_store.ll unaligned_load_store_aeabi.ll
    unaligned_load_store_vfp.ll tc32-distinct-dst-reg-fixup.mir
    tc32-load-hazard-fixup.mir tc32-nonreserved-callframe.mir
    tc32-pop-ret-implicit-return.mir tc32-signed-branch-fixup.mir
    tc32-tb-backward-range-boundary.mir tc32-tb-range-boundary.mir
""".split())
BASELINE_NAMES = BASELINE_PASSES | VISIBLE_FAILURES.keys() | DIAGNOSTIC_CONTROLS
CANDIDATE_REGRESSIONS = {
    "tc32-packed-byte-load-snapshot.ll",
    "tc32-packed-byte-load-snapshot-semantics.ll",
    "tc32-immediate-expand.mir",
    "tc32-island-dead-alignment.mir",
}
CANDIDATE_MC_REGRESSIONS = {"tc32-data-section-padding.s"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_signature(output, group):
    assertion, pass_name = SIGNATURES[group]
    assertions = re.findall(r"Assertion `(.*?)' failed\.", output)
    passes = re.findall(r"Running pass '([^']+)'", output)
    require(assertions == [assertion], f"Wrong or missing {group} assertion")
    require(
        passes == ["Function Pass Manager", pass_name],
        f"Wrong or missing {group} compiler pass identity",
    )
    origin = ("llvm/include/llvm/ADT/ArrayRef.h" if group == "immediate-index"
              else "llvm/lib/Target/ARM/ARMConstantIslandPass.cpp")
    require(re.search(
        rf"^(?:# \| )?llc: .*/{re.escape(origin)}:\d+: .*: Assertion `",
        output, re.MULTILINE,
    ), f"Assertion did not originate in {origin}")


def command_results(output):
    chunks = re.split(r"^# executed command: ", output, flags=re.MULTILINE)[1:]
    results = []
    error_count = 0
    for chunk in chunks:
        command, _, body = chunk.partition("\n")
        errors = re.findall(r"^# error: (.*)$", body, re.MULTILINE)
        error_count += len(errors)
        require(len(errors) <= 1, "Multiple errors in one lit command")
        status = 0
        if errors:
            match = re.fullmatch(r"command failed with exit status: (-?\d+)", errors[0])
            require(match is not None, "Unknown lit runner error")
            status = int(match[1])
        results.append((shlex.split(command), status))
    require(
        error_count == len(re.findall(r"^# error:", output, re.MULTILINE)),
        "Lit runner error outside a recorded command",
    )
    return results


def check_visible_failure(name, output, source_path):
    check_signature(output, VISIBLE_FAILURES[name])
    expected = [("llc", -6), ("FileCheck", 2)]
    if name in ("tc32-inline-asm-rept-branch.ll", "tc32-inline-jt-constpool-layout.ll"):
        expected = [("llc", -6)]
    elif name == "tc32-cttz-constantpool.ll":
        expected.insert(1, ("llvm-objdump", 1))
    results = command_results(output)
    require(
        [(Path(argv[0]).name, status) for argv, status in results if argv] == expected,
        f"Unexpected command outcomes for {name}",
    )
    llc = results[0][0]
    require(
        source_path in llc and "-mtriple=tc32-unknown-none-elf" in llc,
        f"Crash command does not target the selected TC32 test: {name}",
    )
    chunks = re.split(r"^# executed command: ", output, flags=re.MULTILINE)[1:]
    for index, (argv, _) in enumerate(results[1:], start=1):
        tool = Path(argv[0]).name
        arguments = [source_path] if tool == "FileCheck" else ["-d", "-"]
        require(
            argv == [str(Path(llc[0]).with_name(tool)), *arguments],
            f"Unexpected downstream command for {name}",
        )
        diagnostics = re.findall(r"^# \| (.*)$", chunks[index], re.MULTILINE)
        expected_diagnostics = (
            ["FileCheck error: '<stdin>' is empty.",
             f"FileCheck command line:  {argv[0]} {source_path}"]
            if tool == "FileCheck" else
            [f"{argv[0]}: error: '-': The file was not recognized as a valid object file"]
        )
        require(
            diagnostics == expected_diagnostics,
            f"Unknown downstream diagnostic for {name}",
        )
    require(
        re.findall(r"^Exit Code: (-?\d+)$", output, re.MULTILINE)
        == [str(expected[-1][1])],
        f"Unexpected lit test exit for {name}",
    )


def check_diagnostic_failure(name, output, source_path, control):
    results = command_results(output)
    require(len(results) == 2, f"Unexpected diagnostic command count: {name}")
    (command, status), (filecheck, filecheck_status) = results
    require(len(command) == 6 and command[0] == "not", f"Wrong diagnostic command: {name}")
    llc = command[1]
    arguments = ["-mtriple=tc32-unknown-none-elf", source_path, "-o", "/dev/null"]
    require(
        Path(llc).name == "llc" and command == ["not", llc, *arguments],
        f"Wrong diagnostic llc arguments: {name}",
    )
    require(
        filecheck == [str(Path(llc).with_name("FileCheck")), source_path]
        and (status, filecheck_status) == (1, 0)
        and re.findall(r"^Exit Code: (-?\d+)$", output, re.MULTILINE) == ["1"]
        and "Assertion " not in output
        and "# | " not in output
        and "# note: command had no output on stdout or stderr" in output,
        f"Diagnostic lit outcome changed: {name}",
    )
    require(control is not None, f"Missing direct exact-crash control for {name}")
    require(
        control["command"] == [str(Path(llc).with_name("not")), "--crash", llc, *arguments]
        and control["not_status"] == "0\n"
        and control["filecheck_status"] == "0\n"
        and control["stdout"] == "",
        f"Direct diagnostic control did not confirm an exact crash: {name}",
    )
    check_signature(control["stderr"], "immediate-index")
    require(
        "error: TC32 does not support atomic operations" in control["stderr"],
        f"Missing expected diagnostic in direct stderr: {name}",
    )


def classify(variant, status, document, selection, controls):
    require(variant in ("baseline", "candidate"), "Unknown compiler variant")
    require(status in (0, 1), f"llvm-lit runner failed: {status}")
    paths, suites = {}, {}
    for path in selection:
        match = re.fullmatch(
            r".*/llvm/test/(CodeGen/ARM/[^/]+\.(?:ll|mir)|MC/ELF/ARM/[^/]+\.s)",
            path,
        )
        require(match is not None, f"Invalid selected test path: {path}")
        suite, name = match[1].rsplit("/", 1)
        require(name not in paths, f"Duplicate selection: {name}")
        paths[name] = path
        suites[name] = f"LLVM :: {suite}/"
    selected = set(paths)
    required = BASELINE_NAMES
    if variant == "candidate":
        required = required | CANDIDATE_REGRESSIONS | CANDIDATE_MC_REGRESSIONS
    require(required <= selected, "Incomplete selected coverage")
    if variant == "baseline":
        require(selected == BASELINE_NAMES, "Pristine baseline selection changed")
    tests = document["tests"]
    require(isinstance(tests, list) and len(tests) == len(selected), "Incomplete lit results")
    seen = set()
    passed, known = [], []
    for test in tests:
        full_name, code, output = test["name"], test["code"], test["output"]
        require(isinstance(output, str), "Invalid lit output")
        name = full_name.rsplit("/", 1)[-1]
        require(name in selected and name not in seen, f"Unknown or duplicate test: {full_name}")
        require(full_name == suites[name] + name, f"Unexpected suite: {full_name}")
        seen.add(name)
        expect_pass = variant == "candidate" or name in BASELINE_PASSES
        if expect_pass:
            require(code == "PASS", f"Expected PASS, got {code}: {full_name}")
            require(
                re.findall(r"^Exit Code: (-?\d+)$", output, re.MULTILINE) == ["0"]
                and "# error:" not in output,
                f"PASS disagrees with output: {full_name}",
            )
            passed.append(full_name)
            continue
        require(code == "FAIL", f"Expected pinned baseline FAIL, got {code}: {full_name}")
        if name in DIAGNOSTIC_CONTROLS:
            check_diagnostic_failure(name, output, paths[name], controls.get(name))
            group, origin = "immediate-index", f"{name}.control.stderr"
        else:
            check_visible_failure(name, output, paths[name])
            group, origin = VISIBLE_FAILURES[name], "lit.json"
        known.append({
            "name": full_name,
            "group": group,
            "assertion": SIGNATURES[group][0],
            "pass": SIGNATURES[group][1],
            "crash_evidence": origin,
        })
    require(seen == selected, "Missing selected test results")
    require(status == int(bool(known)), "lit exit disagrees with recorded outcomes")
    return {
        "variant": variant,
        "baseline_sha": BASELINE_SHA,
        "reference_run": REFERENCE_RUN,
        "passed": sorted(passed),
        "known_failures": sorted(known, key=lambda item: item["name"]),
        "marker": (
            "BASELINE_LIT_PINNED_FAILURES_CONFIRMED" if variant == "baseline"
            else "CANDIDATE_LIT_PASS"
        ),
    }


def load_controls(evidence):
    controls = {}
    for name in DIAGNOSTIC_CONTROLS:
        fields = {}
        for key, suffix in (
            ("command", "command"), ("not_status", "not-status"),
            ("filecheck_status", "filecheck-status"), ("stdout", "stdout"),
            ("stderr", "stderr"),
        ):
            path = evidence / f"{name}.control.{suffix}"
            if path.is_file():
                fields[key] = path.read_text()
        if fields:
            require(len(fields) == 5, f"Incomplete direct diagnostic control: {name}")
            fields["command"] = fields["command"].splitlines()
            controls[name] = fields
    return controls


def main():
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} baseline|candidate LIT_STATUS EVIDENCE")
    variant, status, directory = sys.argv[1:]
    evidence = Path(directory)
    for name in ("lit-result.txt", "lit-known-failures.txt", "lit-classification.json"):
        (evidence / name).unlink(missing_ok=True)
    try:
        cache = (evidence / "CMakeCache.txt").read_text().splitlines()
        require(
            [line for line in cache if line.startswith("LLVM_ENABLE_ASSERTIONS:")]
            == ["LLVM_ENABLE_ASSERTIONS:BOOL=ON"],
            "Assertions must remain ON",
        )
        if variant == "baseline":
            provenance = (evidence / "provenance.txt").read_text().splitlines()
            require(
                f"llvm_source_sha={BASELINE_SHA}" in provenance
                and f"llvm_baseline_sha={BASELINE_SHA}" in provenance
                and "variant=baseline" in provenance,
                "Baseline provenance is not the pinned pristine revision",
            )
        result = classify(
            variant, int(status), json.loads((evidence / "lit.json").read_text()),
            (evidence / "lit-selection.txt").read_text().splitlines(),
            load_controls(evidence) if variant == "baseline" else {},
        )
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        sys.exit(f"TC32 lit qualification failed: {error}")
    (evidence / "lit-classification.json").write_text(json.dumps(result, indent=2) + "\n")
    (evidence / "lit-known-failures.txt").write_text("".join(
        f"{item['name']}\t{item['group']}\t{item['pass']}\t{item['crash_evidence']}\n"
        for item in result["known_failures"]
    ))
    (evidence / "lit-result.txt").write_text(result["marker"] + "\n")
    print(f"{result['marker']}: {len(result['passed'])} PASS, "
          f"{len(result['known_failures'])} exact baseline failures")


if __name__ == "__main__":
    main()
