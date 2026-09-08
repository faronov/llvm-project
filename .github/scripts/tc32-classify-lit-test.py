#!/usr/bin/env python3
"""Stdlib tests; TC32_LIT_RECORDED_EVIDENCE optionally supplies a run's files directory."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "tc32_classify_lit", Path(__file__).with_name("tc32-classify-lit.py")
)
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)
BIN = "/synthetic/llvm-build/bin"
SOURCE = "/synthetic/llvm-source/llvm/test/CodeGen/ARM"


def crash_text(group):
    assertion, pass_name = classifier.SIGNATURES[group]
    origin = ("llvm/include/llvm/ADT/ArrayRef.h" if group == "immediate-index"
              else "llvm/lib/Target/ARM/ARMConstantIslandPass.cpp")
    return (
        f'llc: /synthetic/{origin}:1: function: Assertion `{assertion}\' failed.\n'
        "1. Running pass 'Function Pass Manager' on module 'test'\n"
        f"2. Running pass '{pass_name}' on function '@f'\n"
    )


def control_for(command):
    llc = command[1]
    return {
        "command": [str(Path(llc).with_name("not")), "--crash", *command[1:]],
        "not_status": "0\n",
        "filecheck_status": "0\n",
        "stdout": "",
        "stderr": "error: TC32 does not support atomic operations\n"
                  + crash_text("immediate-index"),
    }


def fixture(variant="baseline"):
    names = set(classifier.BASELINE_NAMES)
    if variant == "candidate":
        names |= classifier.CANDIDATE_REGRESSIONS
    tests, controls = [], {}
    for name in sorted(names):
        path = f"{SOURCE}/{name}"
        code, output = "PASS", "Exit Code: 0\n"
        if variant == "baseline" and name not in classifier.BASELINE_PASSES:
            code = "FAIL"
            if name in classifier.DIAGNOSTIC_CONTROLS:
                command = ["not", f"{BIN}/llc", "-mtriple=tc32-unknown-none-elf",
                           path, "-o", "/dev/null"]
                output = (
                    "Exit Code: 1\n# executed command: " + " ".join(command)
                    + "\n# note: command had no output on stdout or stderr\n"
                    "# error: command failed with exit status: 1\n"
                    f"# executed command: {BIN}/FileCheck {path}\n"
                )
                controls[name] = control_for(command)
            else:
                tail = (
                    f"# executed command: {BIN}/FileCheck {path}\n"
                    "# | FileCheck error: '<stdin>' is empty.\n"
                    f"# | FileCheck command line:  {BIN}/FileCheck {path}\n"
                    "# error: command failed with exit status: 2\n"
                )
                exit_code = 2
                if name in ("tc32-inline-asm-rept-branch.ll",
                            "tc32-inline-jt-constpool-layout.ll"):
                    tail, exit_code = "", -6
                elif name == "tc32-cttz-constantpool.ll":
                    tail = (
                        f"# executed command: {BIN}/llvm-objdump -d -\n"
                        f"# | {BIN}/llvm-objdump: error: '-': "
                        "The file was not recognized as a valid object file\n"
                        "# error: command failed with exit status: 1\n" + tail
                    )
                output = (
                    f"Exit Code: {exit_code}\n"
                    f"# executed command: {BIN}/llc -mtriple=tc32-unknown-none-elf {path}\n"
                    + crash_text(classifier.VISIBLE_FAILURES[name])
                    + "# error: command failed with exit status: -6\n" + tail
                )
        tests.append({"name": classifier.PREFIX + name, "code": code, "output": output})
    return {"tests": tests}, [f"{SOURCE}/{name}" for name in sorted(names)], controls


class ClassifierTests(unittest.TestCase):
    def setUp(self):
        self.document, self.selection, self.controls = fixture()

    def classify(self, variant="baseline", status=1):
        return classifier.classify(
            variant, status, self.document, self.selection, self.controls
        )

    def record(self, name):
        return next(t for t in self.document["tests"] if t["name"] == classifier.PREFIX + name)

    def test_exact_baseline_inventory(self):
        self.assertEqual(
            {group: len(names) for group, names in classifier.FAILURE_GROUPS.items()},
            {"immediate-index": 21, "island-water": 9, "island-size": 3,
             "island-unalign": 2, "island-wrong-mi": 2},
        )
        result = self.classify()
        self.assertEqual((len(result["passed"]), len(result["known_failures"])), (16, 39))
        self.assertEqual(result["marker"], "BASELINE_LIT_PINNED_FAILURES_CONFIRMED")

    def test_candidate_passes_future_mir_only_if_selected_and_passed(self):
        self.document, self.selection, self.controls = fixture("candidate")
        self.selection.append(f"{SOURCE}/tc32-future-regression.mir")
        self.document["tests"].append({
            "name": classifier.PREFIX + "tc32-future-regression.mir",
            "code": "PASS", "output": "Exit Code: 0\n",
        })
        self.assertEqual(self.classify("candidate", 0)["marker"], "CANDIDATE_LIT_PASS")
        self.document["tests"][-1]["code"] = "FAIL"
        with self.assertRaises(ValueError):
            self.classify("candidate", 1)

    def test_candidate_rejects_every_nonpass_outcome(self):
        self.document, self.selection, self.controls = fixture("candidate")
        for code in ("FAIL", "XFAIL", "XPASS", "UNSUPPORTED", "UNRESOLVED", "TIMEOUT"):
            with self.subTest(code=code):
                self.document["tests"][0]["code"] = code
                with self.assertRaises(ValueError):
                    self.classify("candidate", 1)

    def test_expected_baseline_failures_cannot_pass_or_skip(self):
        for code in ("PASS", "XFAIL", "UNSUPPORTED", "TIMEOUT", "UNRESOLVED"):
            with self.subTest(code=code):
                self.record("tc32-add-imm.ll")["code"] = code
                with self.assertRaises(ValueError):
                    self.classify()

    def test_baseline_pass_cannot_fail_with_known_signature(self):
        test = self.record("legalize-unaligned-load.ll")
        test.update(code="FAIL", output=self.record("tc32-add-imm.ll")["output"])
        with self.assertRaises(ValueError):
            self.classify()

    def test_missing_duplicate_unknown_and_wrong_suite_results(self):
        original = copy.deepcopy(self.document)
        mutations = (
            lambda tests: tests.pop(),
            lambda tests: tests.__setitem__(0, tests[1]),
            lambda tests: tests[0].update(name=classifier.PREFIX + "tc32-unknown.ll"),
            lambda tests: tests[0].update(name="Other :: CodeGen/ARM/i64_volatile_load_store.ll"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                self.document = copy.deepcopy(original)
                mutate(self.document["tests"])
                with self.assertRaises(ValueError):
                    self.classify()

    def test_selection_cannot_shrink_even_with_matching_result_count(self):
        self.selection.pop()
        self.document["tests"].pop()
        with self.assertRaises(ValueError):
            self.classify()

    def test_duplicate_and_unexpected_baseline_selection(self):
        for name in (self.selection[0], f"{SOURCE}/tc32-unknown.ll"):
            with self.subTest(name=name):
                self.selection.append(name)
                with self.assertRaises(ValueError):
                    self.classify()
                self.selection.pop()

    def test_runner_and_disagreeing_exit_status(self):
        for status in (0, 2, 124, 127, 137, -6):
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.classify(status=status)

    def test_wrong_assertion_pass_command_or_runner_output(self):
        test = self.record("tc32-add-imm.ll")
        original = test["output"]
        mutations = (
            lambda out: out.replace("Invalid index!", "another assertion"),
            lambda out: out.replace("TC32 immediate ALU expand", classifier.ISLAND_PASS),
            lambda out: out + crash_text("island-size"),
            lambda out: out.replace("tc32-add-imm.ll", "tc32-ir-fixup.ll"),
            lambda out: out.replace("exit status: -6", "exit status: 137"),
            lambda out: out.replace("exit status: 2", "exit status: 127"),
            lambda out: out.replace("'<stdin>' is empty.", "could not open check file"),
            lambda out: out + "# error: command not found\n",
            lambda out: "# error: runner initialization failed\n" + out,
            lambda out: out + f"# executed command: {BIN}/unknown\n",
            lambda out: out.replace("Exit Code: 2", "Exit Code: 0"),
            lambda out: out.replace("ArrayRef.h", "Other.h"),
            lambda out: out.replace("llc: /synthetic/", "quoted: /synthetic/"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                test["output"] = mutate(original)
                with self.assertRaises(ValueError):
                    self.classify()

    def test_consumed_diagnostics_require_independent_controls(self):
        for name in classifier.DIAGNOSTIC_CONTROLS:
            saved = self.controls.pop(name)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Missing direct"):
                self.classify()
            self.controls[name] = saved

    def test_direct_crash_control_rejects_mismatch(self):
        name = "tc32-atomic-error.ll"
        original = copy.deepcopy(self.controls[name])
        mutations = (
            lambda c: c.update(not_status="1\n"),
            lambda c: c.update(not_status="127\n"),
            lambda c: c.update(filecheck_status="1\n"),
            lambda c: c.update(stdout="unexpected compiler output"),
            lambda c: c.update(stderr="ordinary diagnostic exit"),
            lambda c: c.update(stderr=crash_text("immediate-index")),
            lambda c: c.update(stderr="error: TC32 does not support atomic operations\n"
                               + crash_text("island-size")),
            lambda c: c["command"].append("-O0"),
            lambda c: c["command"].remove("--crash"),
            lambda c: c["command"].__setitem__(4, f"{SOURCE}/tc32-ldrex-error.ll"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                self.controls[name] = copy.deepcopy(original)
                mutate(self.controls[name])
                with self.assertRaises(ValueError):
                    self.classify()

    def test_consumed_diagnostic_lit_outcome_cannot_change(self):
        test = self.record("tc32-atomic-error.ll")
        original = test["output"]
        for old, new in (("exit status: 1", "exit status: 127"),
                         ("not ", "not --crash "), (" -o ", " -O0 -o "),
                         ("Exit Code: 1", "Exit Code: 0")):
            with self.subTest(change=(old, new)):
                test["output"] = original.replace(old, new)
                with self.assertRaises(ValueError):
                    self.classify()

    def test_pass_label_cannot_hide_failure_output(self):
        self.record("legalize-unaligned-load.ll")["output"] = "Exit Code: 1\n"
        with self.assertRaises(ValueError):
            self.classify()

    def test_partial_controls_are_not_accepted(self):
        def read(path):
            return "0\n"

        with patch.object(Path, "is_file", autospec=True,
                          side_effect=lambda path: path.name.endswith(".not-status")), \
             patch.object(Path, "read_text", autospec=True, side_effect=read):
            with self.assertRaisesRegex(ValueError, "Incomplete direct"):
                classifier.load_controls(Path("evidence"))

    def test_cli_rejects_missing_or_invalid_evidence_and_removes_stale_markers(self):
        files = {
            "CMakeCache.txt": "LLVM_ENABLE_ASSERTIONS:BOOL=ON\n",
            "provenance.txt": f"variant=baseline\nllvm_source_sha={classifier.BASELINE_SHA}\n"
                              f"llvm_baseline_sha={classifier.BASELINE_SHA}\n",
            "lit-selection.txt": "\n".join(self.selection),
            "lit.json": json.dumps(self.document),
        }
        for name, contents in (
            ("CMakeCache.txt", "LLVM_ENABLE_ASSERTIONS:BOOL=OFF\n"),
            ("CMakeCache.txt", "LLVM_ENABLE_ASSERTIONS:BOOL=ON\n"
                              "LLVM_ENABLE_ASSERTIONS:BOOL=OFF\n"),
            ("provenance.txt", "llvm_source_sha=wrong\n"),
            ("lit.json", "{"),
            ("lit.json", "{}"),
            ("lit.json", '{"tests": null}'),
            ("lit.json", None),
        ):
            evidence = dict(files, **{name: contents})

            def read(path):
                value = evidence[path.name]
                if value is None:
                    raise FileNotFoundError(path)
                return value

            with self.subTest(file=name, contents=contents), \
                 patch.object(classifier.sys, "argv", ["classifier", "baseline", "1", "evidence"]), \
                 patch.object(Path, "read_text", autospec=True, side_effect=read), \
                 patch.object(Path, "unlink") as unlink, \
                 patch.object(Path, "write_text") as write, \
                 patch.object(classifier, "load_controls", return_value=self.controls):
                with self.assertRaises(SystemExit):
                    classifier.main()
                self.assertEqual(unlink.call_count, 3)
                write.assert_not_called()


@unittest.skipUnless(os.environ.get("TC32_LIT_RECORDED_EVIDENCE"), "Recorded run not supplied")
class RecordedEvidenceTests(unittest.TestCase):
    def load(self, variant):
        evidence = (Path(os.environ["TC32_LIT_RECORDED_EVIDENCE"])
                    / f"tc32-ci-{classifier.REFERENCE_RUN}-evidence-{variant}")
        document = json.loads((evidence / "lit.json").read_text())
        selection = (evidence / "lit-selection.txt").read_text().splitlines()
        return evidence, document, selection

    def test_all_37_visible_baseline_failures_match_exact_signatures(self):
        _, document, selection = self.load("baseline")
        paths = {Path(path).name: path for path in selection}
        checked = set()
        for test in document["tests"]:
            name = test["name"].removeprefix(classifier.PREFIX)
            if name in classifier.VISIBLE_FAILURES:
                with self.subTest(name=name):
                    self.assertEqual(test["code"], "FAIL")
                    classifier.check_visible_failure(name, test["output"], paths[name])
                    checked.add(name)
        self.assertEqual(checked, classifier.VISIBLE_FAILURES.keys())

    def test_recorded_baseline_remains_blocked_without_direct_crash_evidence(self):
        evidence, document, selection = self.load("baseline")
        self.assertEqual(classifier.load_controls(evidence), {})
        with self.assertRaisesRegex(ValueError, "Missing direct exact-crash control"):
            classifier.classify("baseline", 1, document, selection, {})

    def test_recorded_outcomes_with_synthetic_controls_only(self):
        # This exercises classification, not confirmation of the two unobserved crashes.
        _, document, selection = self.load("baseline")
        controls = {}
        for test in document["tests"]:
            name = test["name"].removeprefix(classifier.PREFIX)
            if name in classifier.DIAGNOSTIC_CONTROLS:
                command = classifier.command_results(test["output"])[0][0]
                controls[name] = control_for(command)
        result = classifier.classify("baseline", 1, document, selection, controls)
        self.assertEqual((len(result["passed"]), len(result["known_failures"])), (16, 39))

    def test_recorded_candidate_failures_are_not_allowed(self):
        _, document, selection = self.load("candidate")
        self.assertEqual(sum(t["code"] == "FAIL" for t in document["tests"]), 23)
        with self.assertRaisesRegex(ValueError, "Expected PASS, got FAIL"):
            classifier.classify("candidate", 1, document, selection, {})


if __name__ == "__main__":
    unittest.main()
