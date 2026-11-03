#!/usr/bin/env python3
"""Validate the reviewed synthetic probe's generated binary-search function."""
import ast
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"```python\s*\n(.*?)```", text, flags=re.S)
selected = [block for block in blocks if "def binary_search(" in block]
if len(selected) != 1:
    raise SystemExit("Expected exactly one generated binary-search function.")
tree = ast.parse(selected[0])
if len(tree.body) != 1 or not isinstance(tree.body[0], ast.FunctionDef) or tree.body[0].name != "binary_search":
    raise SystemExit("Unexpected generated program shape.")
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom, ast.Attribute, ast.Global, ast.Nonlocal, ast.Lambda, ast.ClassDef, ast.With, ast.AsyncWith)):
        raise SystemExit("Unexpected capability in generated code.")
    if isinstance(node, ast.Call) and (not isinstance(node.func, ast.Name) or node.func.id != "len"):
        raise SystemExit("Only len() is allowed in this reviewed fixture.")
namespace = {"__builtins__": {"len": len, "list": list, "int": int}}
exec(compile(tree, "<reviewed-synthetic-binary-search>", "exec"), namespace)
function = namespace["binary_search"]
cases = 0
for length in range(65):
    values = [index // 3 - 5 for index in range(length)]
    for target in range(-8, 20):
        result = function(values, target)
        if target in values:
            assert isinstance(result, int) and 0 <= result < len(values) and values[result] == target
        else:
            assert result == -1
        cases += 1
print(f"Generated binary search passed {cases} cases: empty/singleton, duplicates, negative values, hits and misses.")
