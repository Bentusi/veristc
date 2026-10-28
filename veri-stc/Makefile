# veri-stc — 形式化验证编译器组件（Coq 实现+证明 → Extraction → OCaml 可执行文件）
#
# 可独立构建：make -C veri-stc [coq|extract|veristc|dune-veristc|clean-component]
# 产物：$(BUILD_BIN)/veristc（由根 Makefile 统一收敛到 build/bin/）

include ../Makefile.common

ROQCFLAGS = -Q spec veristc_spec -Q src veristc_src

# ── 源文件清单（按依赖顺序）──
SPEC_FILES = spec/safeasm.v spec/safest.v spec/st_semantics.v spec/function_semantics.v spec/asm_semantics.v
SRC_FILES  = src/encoder.v src/lexer.v src/parser.v src/inline.v src/desugar.v \
             src/analysis.v src/typechecker.v src/function_check.v src/codegen.v \
             src/global_codegen.v
EXTRACTION_FILE = extraction/extraction.v

SPEC_VO       = $(SPEC_FILES:.v=.vo)
SRC_VO        = $(SRC_FILES:.v=.vo)
EXTR_VO       = $(EXTRACTION_FILE:.v=.vo)
COMPILER_SRC  = src/compiler_correctness.v
COMPILER_VO   = $(COMPILER_SRC:.v=.vo)

EXTRACT_STAMP    = extraction/.extract_stamp
VERISTC_SRC_BIN  = extraction/veristc
VERISTC_BIN      = $(BUILD_BIN)/veristc

.PHONY: all coq extract veristc dune-build dune-extract dune-veristc clean-component

all: veristc

# ================================================================
# Coq/Rocq 编译
# ================================================================

coq: $(SPEC_VO) $(SRC_VO) $(COMPILER_VO) $(EXTR_VO)

spec/%.vo: spec/%.v
	@echo "  [ROQC] $<"
	@$(ROQC) $(ROQCFLAGS) spec/$*.v

src/%.vo: src/%.v
	@echo "  [ROQC] $<"
	@$(ROQC) $(ROQCFLAGS) src/$*.v

extraction/%.vo: extraction/%.v
	@echo "  [ROQC] $<"
	@$(ROQC) $(ROQCFLAGS) extraction/$*.v

$(COMPILER_VO): $(COMPILER_SRC) $(SPEC_VO) $(SRC_VO)
	@echo "  [ROQC] $<"
	@$(ROQC) $(ROQCFLAGS) src/compiler_correctness.v

# ── 依赖关系 ──
spec/safest.vo:              spec/safeasm.vo
spec/st_semantics.vo:        spec/safest.vo
spec/function_semantics.vo:  spec/safest.vo spec/st_semantics.vo
spec/asm_semantics.vo:       spec/safeasm.vo
src/encoder.vo:              spec/safeasm.vo
src/lexer.vo:                spec/safest.vo
src/parser.vo:               spec/safest.vo src/lexer.vo
src/inline.vo:               spec/safest.vo
src/desugar.vo:              spec/safest.vo spec/st_semantics.vo
src/analysis.vo:             spec/safeasm.vo spec/safest.vo src/desugar.vo
src/typechecker.vo:          spec/safest.vo spec/st_semantics.vo
src/function_check.vo:       spec/safest.vo spec/st_semantics.vo src/typechecker.vo
src/codegen.vo:              spec/safest.vo spec/safeasm.vo spec/st_semantics.vo src/desugar.vo src/analysis.vo
src/global_codegen.vo:       spec/safeasm.vo src/desugar.vo src/analysis.vo src/codegen.vo
extraction/extraction.vo:    $(SPEC_VO) $(SRC_VO)

# ================================================================
# Coq → OCaml Extraction
# ================================================================

$(EXTRACT_STAMP): $(EXTR_VO)
	@echo "  [EXTRACT] Extracting OCaml code..."
	@$(ROQC) $(ROQCFLAGS) $(EXTRACTION_FILE) 2>&1
	@cp extraction/PrimFloat_support_impl.ocaml extraction/PrimFloat.ml
	@cp extraction/PrimFloat_support_iface.ocaml extraction/PrimFloat.mli
	@touch $@
	@echo "  [EXTRACT] Extraction complete"

extract: $(EXTRACT_STAMP)

# veristc_main.ml 为手写源（不参与提取），须显式列为依赖，否则改动不重链接
$(VERISTC_SRC_BIN): $(EXTRACT_STAMP) extraction/veristc_main.ml
	@echo "  [OCAML] Compiling veristc executable..."
	@cd extraction && \
		ocamlfind ocamlopt -package str -linkpkg -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		OCAML_FILES="$$(ocamldep -sort *.ml 2>/dev/null)" && \
		ocamlfind ocamlopt -o veristc -package str -linkpkg $$OCAML_FILES 2>&1 || \
		(ocamlopt -c $$(ocamldep -sort *.mli 2>/dev/null) && \
		 ocamlopt -o veristc str.cmxa $$OCAML_FILES) 2>&1
	@echo "  [OCAML] veristc executable built: $@"

$(VERISTC_BIN): $(VERISTC_SRC_BIN)
	@mkdir -p $(BUILD_BIN)
	cp $< $@

veristc: $(VERISTC_BIN)

# ================================================================
# Dune 构建目标 (P1: 迁移 Coq 构建到 dune)
# ================================================================

dune-build:
	@echo "  [DUNE] Building Coq libraries..."
	@dune build
	@echo "  [DUNE] Coq libraries built successfully"

dune-extract: dune-build
	@echo "  [DUNE] Extracting OCaml code..."
	@dune build @extraction
	@echo "  [DUNE] Extraction complete"

dune-veristc: dune-extract
	@echo "  [DUNE] Building veristc executable..."
	@dune build extraction/veristc.exe
	@mkdir -p $(BUILD_BIN)
	cp _build/default/extraction/veristc.exe $(VERISTC_BIN)
	@echo "  [DUNE] veristc executable built: $(VERISTC_BIN)"

# ================================================================
# 清理（组件自身产物；build/ 由根 Makefile 负责）
# ================================================================

clean-component:
	@echo "  [CLEAN] veri-stc: removing Coq/OCaml artifacts..."
	@find . -type f ! -path './.git/*' \( \
			-name '*.vo' -o -name '*.vos' -o -name '*.vok' -o \
			-name '*.glob' -o -name '*.aux' -o -name '*.cache' -o \
			-name '*.cmi' -o -name '*.cmx' -o -name '*.cmo' -o \
			-name '*.cma' -o -name '*.cmxa' -o -name '*.cmxs' -o \
			-name '*.d' -o -name '*.dep' -o -name '*.annot' -o -name '*.merlin' \) \
		-delete 2>/dev/null || true
	@find extraction -type f \( -name '*.ml' -o -name '*.mli' \) \
		! -name 'veristc_main.ml' -delete 2>/dev/null || true
	@find . -type d ! -path './.git*' \( -name '.coq-native' -o -name '_build' \) \
		-exec rm -rf {} + 2>/dev/null || true
	@dune clean 2>/dev/null || true
