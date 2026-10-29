"""Admission gate for block quality checks."""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .manifest import BlockManifest, AnalysisResult


# Default thresholds
DEFAULT_MAX_WCET = 1000  # cycles
DEFAULT_MAX_STACK_DEPTH = 256
DEFAULT_MAX_LOOP_BOUND = 100


@dataclass
class AdmissionResult:
    """Admission check result."""
    passed: bool
    checks: dict[str, bool]
    errors: list[str]
    warnings: list[str]


class AdmissionGate:
    """Admission gate for block quality checks."""

    def __init__(
        self,
        max_wcet: int = DEFAULT_MAX_WCET,
        max_stack_depth: int = DEFAULT_MAX_STACK_DEPTH,
        max_loop_bound: int = DEFAULT_MAX_LOOP_BOUND,
        require_pure: bool = False,
    ):
        """Initialize admission gate.

        Args:
            max_wcet: Maximum WCET in cycles
            max_stack_depth: Maximum stack depth
            max_loop_bound: Maximum loop bound
            require_pure: Whether to require pure functions
        """
        self.max_wcet = max_wcet
        self.max_stack_depth = max_stack_depth
        self.max_loop_bound = max_loop_bound
        self.require_pure = require_pure

    def check(self, manifest: BlockManifest) -> AdmissionResult:
        """Check if block passes admission gates.

        Args:
            manifest: Block manifest with analysis results

        Returns:
            Admission result
        """
        checks = {}
        errors = []
        warnings = []

        analysis = manifest.analysis
        if not analysis:
            warnings.append("No analysis results available")
            return AdmissionResult(
                passed=True,
                checks=checks,
                errors=errors,
                warnings=warnings,
            )

        # WCET check
        if analysis.wcet_cycles is not None:
            wcet_ok = analysis.wcet_cycles <= self.max_wcet
            checks["wcet"] = wcet_ok
            if not wcet_ok:
                errors.append(
                    f"WCET {analysis.wcet_cycles} exceeds limit {self.max_wcet}"
                )

        # Stack depth check
        if analysis.stack_depth is not None:
            stack_ok = analysis.stack_depth <= self.max_stack_depth
            checks["stack_depth"] = stack_ok
            if not stack_ok:
                errors.append(
                    f"Stack depth {analysis.stack_depth} exceeds limit {self.max_stack_depth}"
                )

        # Loop bound check
        if analysis.loop_bound is not None:
            loop_ok = analysis.loop_bound <= self.max_loop_bound
            checks["loop_bound"] = loop_ok
            if not loop_ok:
                errors.append(
                    f"Loop bound {analysis.loop_bound} exceeds limit {self.max_loop_bound}"
                )

        # Purity check
        if analysis.is_pure is not None:
            pure_ok = analysis.is_pure or not self.require_pure
            checks["pure"] = pure_ok
            if not pure_ok:
                errors.append("Function is not pure (required by policy)")

        passed = all(checks.values()) if checks else True
        return AdmissionResult(
            passed=passed,
            checks=checks,
            errors=errors,
            warnings=warnings,
        )

    def check_from_veristc(
        self,
        manifest: BlockManifest,
        source_path: Path,
        veristc_binary: Path,
    ) -> AdmissionResult:
        """Check block using veristc analysis.

        Args:
            manifest: Block manifest
            source_path: Path to source file
            veristc_binary: Path to veristc binary

        Returns:
            Admission result with analysis from compiler
        """
        import subprocess
        import json

        try:
            # Run veristc analysis
            result = subprocess.run(
                [str(veristc_binary), "-a", str(source_path), "--json"],
                capture_output=True,
                text=True,
                timeout=30,
            )

            if result.returncode != 0:
                return AdmissionResult(
                    passed=False,
                    checks={},
                    errors=[f"Analysis failed: {result.stderr}"],
                    warnings=[],
                )

            # Parse analysis results
            analysis_data = json.loads(result.stdout)
            manifest.analysis = AnalysisResult(
                wcet_cycles=analysis_data.get("wcet_cycles"),
                stack_depth=analysis_data.get("stack_depth"),
                is_pure=analysis_data.get("is_pure"),
                loop_bound=analysis_data.get("loop_bound"),
                compiler_version=analysis_data.get("compiler_version"),
            )

            return self.check(manifest)

        except subprocess.TimeoutExpired:
            return AdmissionResult(
                passed=False,
                checks={},
                errors=["Analysis timed out"],
                warnings=[],
            )
        except Exception as e:
            return AdmissionResult(
                passed=False,
                checks={},
                errors=[f"Analysis error: {str(e)}"],
                warnings=[],
            )
